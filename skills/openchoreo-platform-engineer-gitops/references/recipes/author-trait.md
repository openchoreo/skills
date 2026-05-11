# Recipe — Author a (Cluster)Trait via Git

Add a composable capability that developers can attach to a Component via `spec.traits[]`. Traits can **create** new resources (HPAs, PVCs, ExternalSecrets, etc.) and **patch** existing ones rendered by the ComponentType (e.g. add a volume mount to a Deployment).

## Scope decision

| Scope                 | When                                                                                       | File path                                                  |
| --------------------- | ------------------------------------------------------------------------------------------ | ---------------------------------------------------------- |
| `ClusterTrait` (default) | Platform-wide capability.                                                                | `platform-shared/traits/<name>.yaml`                       |
| `Trait` (namespace-scoped) | Tenant-specific. **Trait validations are namespace-scoped only** — `ClusterTrait` does not support `validations`. | `namespaces/<ns>/platform/traits/<name>.yaml`              |

**Scope rule.** A `ClusterComponentType`'s `allowedTraits` may only reference `ClusterTrait`. A namespace-scoped `ComponentType` may reference either.

## Steps

### 1. Source the shape

Pick one per the shape-lookup decision table in [`../authoring.md`](../authoring.md):

- **Live cluster** — `occ clustertrait get <name>` or `occ trait get <name> -n <ns>`. Strip status / managed fields.
- **Vanilla default** — `observability-alert-rule` at `https://raw.githubusercontent.com/openchoreo/openchoreo/main/samples/getting-started/component-traits/alert-rule-trait.yaml`.
- **Extra shape** — WebFetch from `sample-gitops`:
  - `persistent-volume`, `api-management` at `https://raw.githubusercontent.com/openchoreo/sample-gitops/main/namespaces/default/platform/traits/<name>.yaml`
- **API reference** — `https://openchoreo.dev/docs/reference/api/platform/clustertrait.md` (cluster) or `.../trait.md` (namespace).

> Apply the cluster↔namespace scope swap per [`../authoring.md`](../authoring.md) if the source scope doesn't match what you need.

### 2. Compose the spec

Three load-bearing fields:

- **`creates[]`** — new resources alongside the Component's primary workload. Each entry has `template` (CEL) and optional `includeWhen`.
- **`patches[]`** — modifications to existing resources rendered by the ComponentType (or by another trait that ran first). Each entry has `target` (group / version / kind selector), optional `where` (CEL filter on `resource`), and `operations[]` (JSON-patch-shaped: `op`, `path`, `value`).
- **`parameters.openAPIV3Schema`** — values the developer sets on `spec.traits[].parameters`.
- **`environmentConfigs.openAPIV3Schema`** — per-environment overrides keyed by `instanceName` on `ReleaseBinding.spec.traitEnvironmentConfigs`.

Skeleton (`persistent-volume`-style):

```yaml
# shape: https://openchoreo.dev/docs/reference/api/platform/clustertrait.md (occ v1.0.x)
apiVersion: openchoreo.dev/v1alpha1
kind: ClusterTrait
metadata:
  name: persistent-volume
spec:
  parameters:
    openAPIV3Schema:
      type: object
      required: [volumeName, mountPath]
      properties:
        volumeName:    { type: string }
        mountPath:     { type: string }
        containerName: { type: string, default: main }
  environmentConfigs:
    openAPIV3Schema:
      type: object
      properties:
        size:         { type: string, default: "1Gi" }
        storageClass: { type: string, default: local-path }
  creates:
    - template:
        apiVersion: v1
        kind: PersistentVolumeClaim
        metadata:
          name: ${metadata.name}-${trait.instanceName}
          namespace: ${metadata.namespace}
        spec:
          accessModes: [ReadWriteOnce]
          resources:
            requests:
              storage: ${environmentConfigs.size}
          storageClassName: ${environmentConfigs.storageClass}
  patches:
    - target: { group: apps, kind: Deployment, version: v1 }
      operations:
        - op: add
          path: /spec/template/spec/volumes/-
          value:
            name: ${parameters.volumeName}
            persistentVolumeClaim:
              claimName: ${metadata.name}-${trait.instanceName}
    - target: { group: apps, kind: Deployment, version: v1 }
      operations:
        - op: add
          path: /spec/template/spec/containers/[?(@.name=='${parameters.containerName}')]/volumeMounts/-
          value:
            mountPath: ${parameters.mountPath}
            name: ${parameters.volumeName}
```

### 3. Save and commit

```bash
git checkout -b platform/trait-<name>-$(date +%Y%m%d-%H%M%S)
git add <file>
git commit -s -m "platform: add <ClusterTrait|Trait> <name>"
git push origin HEAD
gh pr create --fill                       # only after user confirmation
```

### 4. Verify after merge

```bash
flux get kustomizations -A
occ clustertrait get <name>                # or occ trait get <name> -n <ns>
```

### 5. Allow-list the new trait

Either:

- Edit each `(Cluster)ComponentType` that should permit this trait — add to `spec.allowedTraits[]`. Commit, PR, reconcile.
- Wait for a developer to ask "why can't I attach this trait?" and surface the answer then.

## CEL specifics for Traits

Trait `creates[]` and `patches[]` have access to:

- `metadata.*` — generated resource name, target namespace, component identity
- `parameters.*` — values from `Component.spec.traits[].parameters`
- `environmentConfigs.*` — per-env overrides
- `dependencies.*`, `dataplane.*`, `gateway.*` — context from the runtime
- **`trait.name` / `trait.instanceName`** — *trait-only*. `instanceName` is what disambiguates multiple attachments of the same trait on one Component.

Inside `patches[].where`, the `resource` variable is the target resource being inspected — filter with `${resource.metadata.name == ...}` etc.

Full availability matrix: [`../cel.md`](../cel.md) §5.

## Multiple instances

A trait can attach to a Component multiple times with different parameters — each attachment has a unique `instanceName`:

```yaml
# Component.spec.traits (developer-side)
traits:
  - kind: ClusterTrait
    name: persistent-volume
    instanceName: data-storage
    parameters:
      volumeName: data
      mountPath: /var/lib/data
  - kind: ClusterTrait
    name: persistent-volume
    instanceName: cache-storage
    parameters:
      volumeName: cache
      mountPath: /var/cache
```

Each generates its own PVC (one named `<x>-data-storage`, one `<x>-cache-storage`) and patches the Deployment accordingly. The trait's CEL refers to `${trait.instanceName}` for collision-free naming.

## Gotchas

- **Patches run in order** — `creates[]` first, then `patches[]` in the order traits appear on the Component. A patch can target a resource a later trait creates. Hidden ordering, easy to surprise yourself; document with comments.
- **`patches[].target` matches by group/version/kind.** Optional `where` narrows further; without `where`, every matching resource gets the patch.
- **`Trait.spec.validations` is namespace-scoped only.** `ClusterTrait` schema has no `validations` field. For platform-wide validation rules, embed them in the `(Cluster)ComponentType` that opt-in to this trait via `allowedTraits`.
- **`creates[].template` must not hardcode `metadata.namespace`** — use `${metadata.namespace}`.
- **`instanceName` collisions are per-component.** If two attachments share an `instanceName`, the CR fails validation at the Component level.

## Related

- [`author-componenttype.md`](./author-componenttype.md) — `(Cluster)ComponentType.allowedTraits` needs updating to permit a new trait
- [`../cel.md`](../cel.md) — CEL syntax, `trait.*` context, patches `where` filters
