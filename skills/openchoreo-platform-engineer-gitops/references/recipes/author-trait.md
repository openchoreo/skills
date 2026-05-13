# Recipe — Author a (Cluster)Trait via Git

Add a composable capability developers attach to a Component via `spec.traits[]`. Traits can **create** new resources (HPAs, PVCs, ExternalSecrets) and **patch** existing ones rendered by the ComponentType (e.g. add a volume mount to a Deployment).

## Scope decision

| Scope | When | Path |
| --- | --- | --- |
| `ClusterTrait` (default) | Platform-wide capability. | `platform-shared/traits/<name>.yaml` |
| `Trait` (namespace-scoped) | Tenant-specific. Also: `Trait.spec.validations` works; **`ClusterTrait` doesn't support `validations`**. | `namespaces/<ns>/platform/traits/<name>.yaml` |

**Scope rule.** A `ClusterComponentType`'s `allowedTraits` may only reference `ClusterTrait`. Namespace-scoped `ComponentType` may reference either.

## Steps

### 1. Source the shape

- **Full schema** — `./scripts/fetch-page.sh --exact --title "ClusterTrait"` (or `"Trait"`).
- **Vanilla default** — `observability-alert-rule` (URL in [`../authoring.md`](../authoring.md)).
- **Extra shape** — `persistent-volume` / `api-management` from `sample-gitops` (URLs in `../authoring.md`).

Apply the cluster↔namespace swap (in `../authoring.md`) if the source scope doesn't match.

### 2. Compose

Load-bearing fields:

- **`creates[]`** — new resources alongside the primary workload. Each entry has `template` (CEL) and optional `includeWhen`.
- **`patches[]`** — modify resources rendered by the ComponentType (or earlier traits). Each: `target` (group / version / kind), optional `where` (CEL filter on `resource`), `operations[]` (JSON-patch-shaped).
- **`parameters.openAPIV3Schema`** — values on `Component.spec.traits[].parameters`.
- **`environmentConfigs.openAPIV3Schema`** — per-env overrides keyed by `instanceName` on `ReleaseBinding.spec.traitEnvironmentConfigs`.

Skeleton (`persistent-volume`):

```yaml
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

### 3. Commit + verify

Branch `platform/trait-<name>-<ts>`, message `"platform: add <ClusterTrait|Trait> <name>"`. Canonical flow in [`../authoring.md`](../authoring.md) *Git workflow*. After merge:

```bash
flux get kustomizations -A
occ clustertrait get <name>                # or occ trait get <name> -n <ns>
```

### 4. Allow-list the new trait

Edit each `(Cluster)ComponentType` that should permit this trait — add to `spec.allowedTraits[]`, commit, PR.

## CEL specifics

`creates[]` / `patches[]` have access to: `metadata.*`, `parameters.*`, `environmentConfigs.*`, `dependencies.*`, `dataplane.*`, `gateway.*`, plus trait-only **`trait.name`** / **`trait.instanceName`** (disambiguates multiple attachments).

Inside `patches[].where`, the `resource` variable is the target being inspected.

Full availability matrix: [`../cel.md`](../cel.md) §5.

## Multiple instances

A trait can attach to a Component multiple times with different parameters — each attachment has a unique `instanceName`:

```yaml
traits:
  - kind: ClusterTrait
    name: persistent-volume
    instanceName: data-storage
    parameters: { volumeName: data, mountPath: /var/lib/data }
  - kind: ClusterTrait
    name: persistent-volume
    instanceName: cache-storage
    parameters: { volumeName: cache, mountPath: /var/cache }
```

Each generates its own PVC and patches the Deployment; the trait's CEL uses `${trait.instanceName}` for collision-free naming.

## Gotchas

- **Patches run in order** — `creates[]` first, then `patches[]` in the order traits appear on the Component. Hidden ordering — document non-obvious dependencies.
- **`patches[].target` matches by group/version/kind.** `where` narrows further; without it, every matching resource gets patched.
- **`ClusterTrait` schema has no `validations` field.** For platform-wide rules, embed them in the `ComponentType` that opts in via `allowedTraits`.
- **`creates[].template` must not hardcode `metadata.namespace`** — use `${metadata.namespace}`.
- **`instanceName` collisions are per-component.** Two attachments sharing an `instanceName` fails Component-level validation.
