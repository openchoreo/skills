# Recipe — Attach a PE-authored Trait to a Component

Traits are platform-engineer authored (`(Cluster)Trait` CRDs in `platform-shared/traits/` or `namespaces/<ns>/platform/traits/`). Developers *attach* them to Components by listing in `Component.spec.traits[]`. Each attachment needs a unique `instanceName`.

**Authoring** a Trait is platform-side work and out of scope for this skill.

## Steps

### 1. Discover available traits

```bash
occ clustertrait list                            # cluster-scoped
occ trait list -n <ns>                           # namespace-scoped
```

For each candidate:

```bash
occ clustertrait get <name>                      # inspect the spec
# or:
occ trait get <name> -n <ns>
```

Read `spec.parameters.openAPIV3Schema` and `spec.environmentConfigs.openAPIV3Schema` — they describe what `Component.spec.traits[].parameters` and `ReleaseBinding.spec.traitEnvironmentConfigs[<instanceName>]` accept.

### 2. Confirm the ComponentType allows it

The ComponentType has `allowedTraits[]`. If your trait isn't there, attempts to attach fail with `TraitNotAllowed`. Two options:

- Ask the PE to add the trait to `allowedTraits[]` (PE skill, ComponentType author recipe).
- Pick a different ComponentType that allows it (if applicable).

```bash
occ clustercomponenttype get <name>              # or occ componenttype get <name> -n <ns>
# Look at spec.allowedTraits[]
```

### 3. Attach the trait

Edit `Component.spec.traits[]`:

```yaml
spec:
  owner:
    projectName: <project>
  componentType:
    name: database
    kind: ComponentType
  parameters:
    port: 5432
  traits:
    - kind: Trait                                # or ClusterTrait
      name: persistent-volume
      instanceName: data-storage                 # **unique** per attachment on this component
      parameters:
        volumeName: pg-data
        mountPath: /var/lib/postgresql/data
        containerName: main
```

Required fields:

- `kind` — `Trait` (namespace-scoped) or `ClusterTrait`. Defaults to `ClusterTrait` if omitted; **set explicitly when referencing a namespace-scoped trait**.
- `name` — the trait's `metadata.name`.
- `instanceName` — a unique identifier for this attachment on this Component. Must be unique within `spec.traits[]`. Used by:
  - The trait's CEL templates (`${trait.instanceName}`) for collision-free resource naming.
  - `ReleaseBinding.spec.traitEnvironmentConfigs[<instanceName>]` for per-env overrides.
- `parameters` — values matching the trait's `parameters.openAPIV3Schema`. Required fields per the schema.

### 4. Multiple attachments of the same trait

A trait can attach multiple times with different parameters. Each attachment gets a unique `instanceName`:

```yaml
spec:
  traits:
    - kind: ClusterTrait
      name: persistent-volume
      instanceName: data
      parameters:
        volumeName: data
        mountPath: /var/lib/data
    - kind: ClusterTrait
      name: persistent-volume
      instanceName: cache
      parameters:
        volumeName: cache
        mountPath: /var/cache
```

Each generates its own PVC (e.g. `<resource-name>-data`, `<resource-name>-cache`) and applies its own patches to the Deployment.

### 5. Commit, generate release, PR

If `autoDeploy: true` and the Component already has a Workload, the trait attachment will produce a new ComponentRelease automatically on apply. Otherwise generate a new release explicitly:

```bash
# Component-only change → new ComponentRelease + ReleaseBinding(s)
occ componentrelease generate \
  --mode file-system --root-dir <repo> \
  --project <project> --component <component>

# Optionally regenerate ReleaseBindings for envs where the change should land:
occ releasebinding generate \
  --mode file-system --root-dir <repo> \
  --project <project> --component <component> \
  --target-env development --use-pipeline standard
```

Branch `release/<component>-trait-<trait-name>-<ts>`, paths `namespaces/<ns>/projects/<project>/components/<component>/`, message `"Component <component>: attach <trait-name> trait"`. Canonical flow in [`../authoring.md`](../authoring.md) *Git workflow*.

### 6. Verify

```bash
flux get kustomizations -A
occ component get <component> -n <ns>            # spec.traits[] reflects the attachment
occ releasebinding get <component>-<env> -n <ns> # Ready=True
```

For the trait's generated resources (e.g. PVC for `persistent-volume`):

```bash
# Once the trait creates a resource, it shows up on the data plane:
kubectl get pvc -n <runtime-namespace>           # or whatever the trait creates
```

## Per-environment trait overrides

Trait `environmentConfigs` (e.g. PVC size, HPA bounds, alert thresholds) lives on the **ReleaseBinding**, keyed by `instanceName`:

```yaml
# ReleaseBinding (per env)
spec:
  traitEnvironmentConfigs:
    data:
      size: 10Gi
      storageClass: ssd
    cache:
      size: 5Gi
      storageClass: local-path
```

The `data` / `cache` keys match the `instanceName` from the Component's `traits[]`. Values match the trait's `environmentConfigs.openAPIV3Schema`.

See [`override-per-environment.md`](./override-per-environment.md).

## Gotchas

- **`TraitNotAllowed` error** — the ComponentType's `allowedTraits[]` doesn't include this trait. Edit the ComponentType (PE side) or pick a different one.
- **Scope rule.** A `ClusterComponentType`'s `allowedTraits` may only reference `ClusterTrait`. If your Component uses a `ClusterComponentType`, you can attach only `ClusterTrait`s, even if a namespace-scoped `Trait` exists with the same name.
- **`instanceName` collisions are per-component.** Two attachments with the same `instanceName` fail admission. Across Components, no constraint — different Components can both have `instanceName: data`.
- **`instanceName` is used by CEL templates.** Picking generic names like `default` or `main` is fine but doesn't tell you anything about what the trait does. `data-storage`, `cache-storage`, `prometheus-alerts` are more readable.
- **Trait parameter schemas are required-by-default.** Missing a required parameter without a `default` fails admission.

## Related

- [`onboard-component-byo.md`](./onboard-component-byo.md), [`onboard-component-source-build.md`](./onboard-component-source-build.md)
- [`override-per-environment.md`](./override-per-environment.md) — `traitEnvironmentConfigs[<instanceName>]`
- [`../concepts.md`](../concepts.md) *Trait*-related sections
