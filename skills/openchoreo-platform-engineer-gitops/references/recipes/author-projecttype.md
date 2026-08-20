# Recipe — Author a (Cluster)ProjectType via Git

Define a project's **cell infrastructure** template — the data-plane namespace every project runs in plus the namespace-scoped policy around it (NetworkPolicies, ResourceQuotas, baseline RBAC, image-pull secrets). Commit, PR, reconcile.

Tweaking an existing ProjectType uses the same recipe — edit the file, commit, Flux re-applies the full spec.

## Scope decision

| Scope | When | Path |
| --- | --- | --- |
| `ClusterProjectType` (default) | Visible to every namespace — platform-wide cell template. | `platform-shared/project-types/<name>.yaml` |
| `ProjectType` (namespace-scoped) | Tenant isolation, stricter parameter schemas, per-tenant policy. | `namespaces/<ns>/platform/project-types/<name>.yaml` |

The specs are structurally identical; convert by swapping `kind:` and adding / removing `metadata.namespace:`. A Project references its type with `spec.type: {kind, name}` (`kind` defaults to `ProjectType`).

## The cell-namespace mandate

Every ProjectType's `resources[]` **must** declare the cell namespace itself — a `v1/Namespace` entry whose `metadata.name` is the literal `${metadata.namespace}` placeholder (the platform-computed `dp-{ns}-{project}-{env}-{hash}` name). This gives the namespace an explicit owner (the ProjectReleaseBinding). Enforcement is against the **rendered** output, in the binding controller: a missing or `includeWhen`-suppressed entry surfaces `Synced=False, Reason=NamespaceMissing` and nothing is applied. **Never guard the mandated Namespace.** `${metadata.namespace}` is the cell namespace: the mandated Namespace uses it as `metadata.name`; every other resource uses it as `metadata.namespace`.

## Steps

### 1. Source the shape

Per [`../authoring.md`](../authoring.md) *Shape-lookup*:

- **Full schema** — `./scripts/fetch-page.sh --exact --title "ClusterProjectType"` (or `"ProjectType"`).
- **Default for inspiration** — `./scripts/extract-resources.sh defaults --kind ClusterProjectType --name default` (the shipped `default` type; provisions only the cell namespace, accepts `namespaceLabels` / `namespaceAnnotations` per-env).
- **What's installed on the live cluster** — `occ clusterprojecttype get <name>` / `occ projecttype get <name> -n <ns>`.

### 2. Compose

Four load-bearing fields (ProjectType has **no** `outputs`, `readyWhen`, or `retainPolicy` — it provisions the cell, it doesn't publish connection details):

- **`parameters.openAPIV3Schema`** — project-author-facing knobs (from `Project.spec.parameters`). Frozen into the `ProjectRelease` snapshot.
- **`environmentConfigs.openAPIV3Schema`** — per-env knobs (quotas, policy toggles) from `ProjectReleaseBinding.spec.environmentConfigs`. Re-evaluated on every binding reconcile.
- **`validations[]`** — `${...}`-wrapped boolean CEL rules + plain-English `message`; all must pass for rendering.
- **`resources[]`** — namespace-scoped K8s templates with CEL. Each has `id`, `template`, optional `includeWhen`, `forEach` (+ required `var`), `targetPlane` (`dataplane` default / `observabilityplane`). **Must include the mandated cell-namespace entry.**

Skeleton:

```yaml
apiVersion: openchoreo.dev/v1alpha1
kind: ClusterProjectType
metadata:
  name: standard-project
spec:
  parameters:
    openAPIV3Schema:
      type: object
      properties:
        tier: { type: string, enum: [standard, premium], default: standard }

  environmentConfigs:
    openAPIV3Schema:
      type: object
      properties:
        cpuQuota: { type: string, default: "4" }
        allowMonitoringEgress: { type: boolean, default: false }

  validations:
    - rule: "${environmentConfigs.cpuQuota.matches('^[0-9]+$')}"
      message: "cpuQuota must be an integer string"

  resources:
    - id: cell-namespace                    # mandated — never guarded
      template:
        apiVersion: v1
        kind: Namespace
        metadata:
          name: ${metadata.namespace}
          labels: ${metadata.labels}

    - id: resource-quota
      template:
        apiVersion: v1
        kind: ResourceQuota
        metadata:
          name: project-quota
          namespace: ${metadata.namespace}
        spec:
          hard:
            limits.cpu: ${environmentConfigs.cpuQuota}

    - id: allow-monitoring-egress           # conditional entry
      includeWhen: "${environmentConfigs.allowMonitoringEgress}"
      template:
        apiVersion: networking.k8s.io/v1
        kind: NetworkPolicy
        metadata:
          name: allow-monitoring-egress
          namespace: ${metadata.namespace}
        # ...
```

CEL surface for templates / `includeWhen` / `forEach` / `validations`: `metadata.*` (incl. `namespace` = the cell namespace), `parameters.*`, `environmentConfigs.*`, `environment.*`, `dataplane.*`, `gateway.*`. There is **no `applied.*`** (no `readyWhen`/`outputs`). Guard a possibly-missing gateway with `has(environment.gateway)` — `has(gateway)` is invalid CEL. Built-ins: `oc_omit()`, `oc_merge()`, `oc_generate_name()`, `oc_dns_label()` (`oc_merge(metadata.labels, environmentConfigs.namespaceLabels)` is the idiom for layering per-env labels onto the cell namespace). Full surface in [`../cel.md`](../cel.md).

### 3. Commit + verify

Branch `platform/projecttype-<name>-<ts>`, commit message `"platform: add <ClusterProjectType|ProjectType> <name>"`. Canonical flow in [`../authoring.md`](../authoring.md) *Git workflow*. After merge:

```bash
flux get kustomizations -A
occ clusterprojecttype get <name>            # or occ projecttype get <name> -n <ns>
```

### 4. Smoke test

Have a developer point a `Project` at the new type and deploy its cell (a `ProjectReleaseBinding` per env — application-side, see the developer-gitops skill):

```yaml
# Project.spec
spec:
  deploymentPipelineRef: { name: default }
  type:
    kind: ClusterProjectType
    name: standard-project
  parameters:
    tier: premium
```

```bash
occ project get <p> -n <ns>                   # status.latestRelease.name populated ({project}-{hash})
occ projectreleasebinding get <p>-<env> -n <ns>
# Synced → NamespaceReady → ResourcesReady → Ready (all True); status.namespace = the cell namespace
```

`Synced=False, Reason=NamespaceMissing` → the type didn't declare the mandated `v1/Namespace` (or an `includeWhen` suppressed it). Other `Synced=False` reasons (`ProjectReleaseNotSet` / `ProjectReleaseNotFound` / `InvalidReleaseConfiguration` / `RenderingFailed` / `EnvironmentNotFound` / `DataPlaneNotFound`) name what's missing; a failing `validations` rule surfaces its message here. See [`../concepts.md`](../concepts.md) *Verification ladder*.

## Updating an existing ProjectType

Flux re-applies the full file every reconcile — **anything not in the file is removed; don't half-edit.** A PE edit to the inlined type spec cuts a new `ProjectRelease` on every consuming Project (the Project controller hashes `ProjectType.spec + Project.parameters`). Existing `ProjectReleaseBinding`s stay pinned to the old release until promoted (bump `spec.projectRelease` in Git on the binding). For a backward-incompatible change, version the type (`standard-project-v2.yaml`) rather than editing in place.

## Variants

**Namespace-scoped tenancy** — same shape, `kind: ProjectType`, set `metadata.namespace`, path `namespaces/<ns>/platform/project-types/`. Project references it with `type.kind: ProjectType`.

**Minimal (namespace-only) type** — the shipped `default` ClusterProjectType: a single mandated `cell-namespace` entry, `environmentConfigs` accepting `namespaceLabels` / `namespaceAnnotations` maps `oc_merge`d onto the namespace. Use it as the starting point when a tenant needs no policy beyond a bare namespace.

## Gotchas

- **The mandated cell-namespace entry is required and must not be guarded.** Missing / suppressed → `NamespaceMissing`, nothing applies.
- **No `outputs` / `readyWhen` / `retainPolicy` / `applied.*`** on ProjectType — those belong to ResourceType. Readiness is per-Kind health on the `RenderedRelease`, surfaced on the binding's `ResourcesReady`.
- **`Project.spec.type` is immutable.** Re-targeting a project to a different type means delete + recreate the Project.
- **`var` is required when `forEach` is set** — the webhook rejects `forEach` without `var`.
- **`metadata.namespace` substitution.** Don't hardcode literal namespaces in templates; use `${metadata.namespace}` (the cell namespace).
- **No webhook-side schema validation on `ProjectReleaseBinding.spec.environmentConfigs`.** Invalid env-config data surfaces at render time as `Synced=False, Reason=RenderingFailed`.

## Related

- [`../concepts.md`](../concepts.md) *Resource hierarchy*, *Cluster vs namespace scope*, *Immutability and update semantics*
- [`../cel.md`](../cel.md) — CEL surface for `template` / `includeWhen` / `forEach` / `validations`
- [`author-resourcetype.md`](./author-resourcetype.md) / [`author-componenttype.md`](./author-componenttype.md) — parallel authoring patterns
- [`install-defaults.md`](./install-defaults.md) — materialise the shipped `default` ClusterProjectType
