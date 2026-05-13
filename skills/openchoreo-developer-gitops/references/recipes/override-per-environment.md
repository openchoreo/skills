# Recipe — Per-environment overrides on a ReleaseBinding

Same `ComponentRelease` deploys to multiple Environments; the `ReleaseBinding` carries what varies per env. Three override surfaces.

## The three override fields

| Field                              | What it overrides                                         | Schema source                                                |
| ---------------------------------- | --------------------------------------------------------- | ------------------------------------------------------------ |
| `componentTypeEnvironmentConfigs`  | ComponentType `environmentConfigs` — replicas, resources, imagePullPolicy, custom fields the type defines. | `(Cluster)ComponentType.spec.environmentConfigs.openAPIV3Schema` |
| `traitEnvironmentConfigs`          | Each trait's `environmentConfigs` — keyed by `instanceName`. PVC size, HPA bounds, alert thresholds, …    | `(Cluster)Trait.spec.environmentConfigs.openAPIV3Schema`    |
| `workloadOverrides`                | Workload-level env vars / files differing per env.       | Free-form (matches Workload spec shape)                       |

## Discovering what's available to override

```bash
occ clustercomponenttype get <name>
# spec.environmentConfigs.openAPIV3Schema describes what componentTypeEnvironmentConfigs accepts

occ clustertrait get <name>
# spec.environmentConfigs.openAPIV3Schema describes per-trait overrides

occ workload get <component>-workload -n <ns>
# Look at container.env[], container.files[] — workloadOverrides lets you add / replace specific entries
```

The PE-authored `environmentConfigs` schema is the contract. Required fields are required-by-default unless they have `default`; passing an unknown field will fail validation.

## Examples

### Replicas + resources

```yaml
# release-bindings/<component>-production.yaml
apiVersion: openchoreo.dev/v1alpha1
kind: ReleaseBinding
metadata:
  name: <component>-production
  namespace: <ns>
spec:
  environment: production
  owner:
    componentName: <component>
    projectName: <project>
  releaseName: <release-name>
  componentTypeEnvironmentConfigs:
    replicas: 5
    resources:
      requests:
        cpu: "500m"
        memory: "512Mi"
      limits:
        cpu: "2000m"
        memory: "2Gi"
    imagePullPolicy: IfNotPresent
```

The `componentTypeEnvironmentConfigs` keys must match the ComponentType's `environmentConfigs.openAPIV3Schema`. Check the live schema before authoring.

### Trait overrides per instance

```yaml
spec:
  traitEnvironmentConfigs:
    data-storage:                                # instanceName from Component.spec.traits[]
      size: 100Gi
      storageClass: ssd
    cache-storage:
      size: 10Gi
      storageClass: local-path
```

For an `observability-alert-rule` trait:

```yaml
spec:
  traitEnvironmentConfigs:
    high-error-rate:                             # instanceName
      threshold: 0.05                            # 5% per the trait's schema
      severity: critical
```

### Workload-level env override

When a per-env value can't be expressed via a dependency or a SecretReference:

```yaml
spec:
  workloadOverrides:
    env:
      - key: FEATURE_FLAGS
        value: "x=true,y=false"
      - key: LOG_LEVEL
        value: warn                              # development uses 'info'; production warns
    files:
      - key: /etc/app/region.json
        mountPath: /etc/app/region.json
        value: |
          {"region": "eu-west"}
```

`workloadOverrides.env[]` and `workloadOverrides.files[]` merge into the Workload's `container.env[]` / `container.files[]` at render time. Entries with the same `key` replace; new keys add.

### Combined

```yaml
spec:
  environment: production
  owner:
    componentName: <component>
    projectName: <project>
  releaseName: <release-name>
  componentTypeEnvironmentConfigs:
    replicas: 5
    resources:
      limits: { cpu: "2000m", memory: "2Gi" }
  traitEnvironmentConfigs:
    data-storage:
      size: 100Gi
  workloadOverrides:
    env:
      - key: LOG_LEVEL
        value: warn
```

## Workflow

`occ releasebinding generate` produces a base binding without overrides. After generation, **edit the file** to add overrides:

```bash
occ releasebinding generate \
  --mode file-system --root-dir <repo> \
  --project <project> --component <component> \
  --target-env production --use-pipeline standard \
  --component-release <release-name>

# Then edit:
# namespaces/<ns>/projects/<project>/components/<component>/release-bindings/<component>-production.yaml
```

Commit, PR, reconcile.

## Cross-env strategy

A common pattern:

- **`development`** — defaults from the ComponentType / Trait (no overrides).
- **`staging`** — overrides closer to prod (more replicas, real resource limits) to surface scaling / OOM issues.
- **`production`** — full overrides.

Surface this choice to the user explicitly. The platform doesn't enforce a strategy; it's whatever the team agrees on.

## When the schema doesn't model the value

The ComponentType / Trait `environmentConfigs.openAPIV3Schema` is the contract. If you need to override something the schema doesn't expose (e.g. an arbitrary annotation, a sidecar config), three options:

1. **Ask the PE to extend the schema** — the right move when the field is generally useful.
2. **Use `workloadOverrides`** — works for env vars and files. Other Workload fields (endpoints, dependencies) are environment-agnostic on purpose.
3. **Author per-env Components** — heavy. Generally an anti-pattern; one Component, many ReleaseBindings is the design.

## Gotchas

- **`componentTypeEnvironmentConfigs` is keyed off the ComponentType's schema**, not the Workload's. Don't put `replicas` directly in `workloadOverrides` — it won't apply. Look at the ComponentType's `environmentConfigs.openAPIV3Schema` to know what's available.
- **`traitEnvironmentConfigs` is keyed by `instanceName`**, not trait name. Two attachments of the same trait have different `instanceName`s — each gets its own override block.
- **`workloadOverrides.env[]` and `files[]` use the CR shape (`key`)**, not the descriptor shape (`name`).
- **Required-by-default in JSON Schema** — leaving out a required field with no default fails admission. If a Trait's `environmentConfigs` requires `size` (no default), the binding must set it.
- **Override values must match types.** `replicas: "5"` (string) fails when the schema says `type: integer`. Easy YAML pitfall.

## Related

- [`promote.md`](./promote.md), [`bulk-promote.md`](./bulk-promote.md)
- [`onboard-component-byo.md`](./onboard-component-byo.md), [`onboard-component-source-build.md`](./onboard-component-source-build.md)
- [`attach-trait.md`](./attach-trait.md) — `instanceName` matters for `traitEnvironmentConfigs`
- [`../concepts.md`](../concepts.md) *ReleaseBinding*
