# ProjectTypes

This file is the authoring reference for **ProjectTypes** and **ClusterProjectTypes** — the templates platform engineers create to define a project's **cell infrastructure**: the data-plane namespace every project runs in, plus the namespace-scoped policy that wraps it (NetworkPolicies, ResourceQuotas, baseline RBAC, image-pull secrets, …).

For the CEL expressions used throughout, see [`cel.md`](./cel.md). For the `parameters` / `environmentConfigs` schema syntax and `resources[]` templating reused here, see [`component-types-and-traits.md`](./component-types-and-traits.md) and [`resource-types.md`](./resource-types.md) — ProjectType shares those systems.

**Tool surface:** MCP-first, **scope-collapsed** — `create_project_type` / `get_project_type` / `update_project_type` / `delete_project_type` / `list_project_types` each take a `scope` arg: `"namespace"` (default; the namespaced `ProjectType` in `namespace_name`) or `"cluster"` (the platform-wide `ClusterProjectType`). So `create_project_type` with `scope: "cluster"` authors a `ClusterProjectType`. Discover the spec body via `get_project_type_creation_schema` (also `scope`-aware). Reads (`list_*` / `get_*` / `get_*_schema`) are also available to the developer toolset. `update_project_type` is **full-spec replacement**: read the current spec via `get_project_type` first, modify locally, send the whole spec back. For one-line CEL or template tweaks, `kubectl apply -f` against an edited YAML is often easier; both paths are equivalent.

Contents:

1. Concepts — what a ProjectType is, scope rules, the project release chain, the cell-namespace mandate
2. Authoring (skeleton, `parameters` / `environmentConfigs`, `validations`, `resources[]`)
3. CEL surface
4. How developers consume a ProjectType
5. Defaults that ship
6. Verification

---

## 1. Concepts

| Resource | Scope | Defines |
|---|---|---|
| `ProjectType` | namespace | Parameter schema, per-env config schema, CEL validations, the cell-namespace + policy manifests |
| `ClusterProjectType` | cluster-wide | Same shape; available in every namespace |

A ProjectType is to a **Project's cell** what a ComponentType is to a Component and a ResourceType is to managed infrastructure. It captures the namespace-scoped manifests the platform renders for each project × environment, the parameters project authors supply, and the per-environment overrides bindings apply.

### Scope rules

- `ProjectType` and `ClusterProjectType` are **interchangeable in shape** — the specs are structurally identical. Convert by swapping `kind:` and adding / removing `metadata.namespace:`.
- A Project references its type via `spec.type: {kind, name}`. `kind` defaults to `ProjectType`; use `ClusterProjectType` for the cluster-scoped one.
- `spec.type` is **required and immutable** on a Project — a project cannot be re-targeted to a different type after creation. Changing which type a project uses means recreating the project.

### Where ProjectType sits in the deploy flow

The same `{Thing} + {Thing}Type → {Thing}Release → {Thing}ReleaseBinding → data plane` pattern as components and resources, at the project level:

```
Project (developer, spec.type + spec.parameters) → ProjectRelease (auto-cut, immutable) →
  ProjectReleaseBinding (per-env) → RenderedRelease (on DataPlane) → the cell namespace + policy
```

The **Project controller** cuts an immutable `ProjectRelease` named `{project}-{hash}` whenever the inlined type spec or `Project.spec.parameters` changes (snapshot of `{ProjectType.spec, Project.parameters}`); the newest is recorded on `Project.status.latestRelease`. A `ProjectReleaseBinding` per environment pins a `ProjectRelease` and triggers the render — authored explicitly (client-created, never controller-created; see 4). The binding controller renders the type's `resources[]` with the snapshot + env overrides, **owns the cell namespace**, and applies the result. Component and Resource deployments to an environment wait for that cell namespace to exist first.

**v1 scope.** A ProjectRelease snapshots the **type + parameters only**; the ProjectReleaseBinding owns the cell namespace and applies the project-type resources. It does **not** bundle or fan out component / resource releases — components and resources still bind individually through their own `ReleaseBinding`s / `ResourceReleaseBinding`s. Document only this shipped behavior.

### The cell-namespace mandate

Every ProjectType's `resources[]` **must** declare the cell namespace itself — a `v1/Namespace` entry whose `metadata.name` is the literal `${metadata.namespace}` placeholder (the platform-computed `dp-{ns}-{project}-{env}-{hash}` name). This gives the namespace an explicit owner (the ProjectReleaseBinding) and a lifecycle tied to the project × environment.

```yaml
resources:
  - id: cell-namespace
    template:
      apiVersion: v1
      kind: Namespace
      metadata:
        name: ${metadata.namespace}       # MUST be this placeholder, literally
        labels: ${metadata.labels}
```

Enforcement is against the **rendered** output, in the binding controller — not a webhook. If the entry is missing, or an `includeWhen` guard suppresses it, the binding reports `Synced=False, Reason=NamespaceMissing` and nothing is applied. **Never guard the mandated Namespace entry.** `${metadata.namespace}` is the cell namespace: the mandated Namespace uses it as `metadata.name`; **every other resource uses it as `metadata.namespace`.**

---

## 2. Authoring

### Skeleton

```yaml
apiVersion: openchoreo.dev/v1alpha1
kind: ClusterProjectType                   # or ProjectType (+ metadata.namespace)
metadata:
  name: standard-project
spec:
  # Project-author-facing values; frozen into the ProjectRelease snapshot.
  parameters:
    openAPIV3Schema:
      type: object
      properties: { ... }                  # see Schema syntax in component-types-and-traits.md

  # Per-environment overrides applied through ProjectReleaseBinding.
  environmentConfigs:
    openAPIV3Schema:
      type: object
      properties: { ... }                  # same shape as parameters

  # CEL rules evaluated during rendering. All must be true.
  validations:
    - rule: "${environmentConfigs.cpuQuota.matches('^[0-9]+$')}"
      message: 'cpuQuota must be an integer string'

  # Namespace-scoped manifests rendered onto the data plane. MUST include the cell namespace.
  resources:
    - id: cell-namespace                   # the mandated Namespace entry — never guarded
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
    - id: allow-monitoring-egress          # conditional entry
      includeWhen: "${environmentConfigs.allowMonitoringEgress}"
      template: { apiVersion: networking.k8s.io/v1, kind: NetworkPolicy, ... }
```

### `parameters` vs `environmentConfigs`

- **`parameters`** — values from `Project.spec.parameters`. **Static across environments.** Frozen into the `ProjectRelease` snapshot when the controller cuts the release. Editing `Project.spec.parameters` cuts a new release; existing bindings stay pinned until promoted.
- **`environmentConfigs`** — values from `ProjectReleaseBinding.spec.environmentConfigs`. **Per-environment.** Validated against the schema on the pinned release and re-evaluated on binding reconcile; changing them updates the binding, no new release. This is how the same release runs different quotas / labels / policy per environment.

Both use the same `openAPIV3Schema` shape documented in [`component-types-and-traits.md`](./component-types-and-traits.md). Defaults are applied before CEL evaluation.

### `validations`

List of `${...}`-wrapped boolean CEL rules, each paired with a plain-English `message`. All must be true for rendering to proceed; a failing rule blocks the render and surfaces the message on the binding's conditions. Rules share the template CEL surface, so they can validate cross-field combinations across `parameters` / `environmentConfigs`.

### `resources[]`

List of named manifest entries, each with a stable `id` (the `listMapKey`; render in spec order). Each entry:

- `id` — unique identifier (string, required). The rendered object's `metadata.name` is unrelated.
- `template` — the K8s manifest, with `${...}` CEL substitutions throughout.
- `includeWhen` (optional) — boolean CEL; when `false`, the entry is omitted and any previously-applied object is GC'd from the data plane. **Do not put it on the mandated Namespace.**
- `forEach` (optional) — CEL yielding a list; generates one object per item. **`var` is required when `forEach` is set** (names the loop variable; webhook rejects `forEach` without `var`).
- `targetPlane` (optional) — `dataplane` (default) or `observabilityplane`.

Unlike ResourceType, ProjectType entries have **no `readyWhen` and no `outputs`** — a project type provisions the cell, it doesn't publish connection details. Readiness is evaluated by the per-Kind health heuristics on the `RenderedRelease` and surfaced on the binding's `ResourcesReady` condition.

---

## 3. CEL surface

Available to `resources[]` templates, `includeWhen` / `forEach`, and `validations`:

| Context | Description |
|---|---|
| `metadata.*` | Platform-injected: `namespace` (the cell namespace), `projectNamespace`, `projectName`, `environmentName`, `dataPlaneName`, project / environment / data-plane UIDs, `labels`, `annotations` |
| `parameters.*` | `Project.spec.parameters` after schema defaulting, as captured in the pinned ProjectRelease |
| `environmentConfigs.*` | `ProjectReleaseBinding.spec.environmentConfigs` after schema defaulting |
| `environment.*` | Per-environment surface, including the merged effective gateway |
| `dataplane.*` | Target DataPlane attributes |
| `gateway.*` | Effective gateway (Environment-level override merged onto the DataPlane-level default) |

Notes:

- There is **no `applied.*` context** on project types (no `readyWhen` / `outputs` to consume it).
- Guard a possibly-missing gateway with `has(environment.gateway)` — **`has(gateway)` is invalid CEL** (the top-level `gateway` alias is omitted when no gateway is configured).
- Built-ins available: `oc_omit()`, `oc_merge()`, `oc_generate_name()`, `oc_dns_label()`. `oc_merge(metadata.labels, environmentConfigs.namespaceLabels)` is the idiom for layering per-env labels onto the cell namespace.

---

## 4. How developers consume a ProjectType

A developer (or the scaffolder) authors a `Project` referencing the type:

```yaml
apiVersion: openchoreo.dev/v1alpha1
kind: Project
metadata:
  name: online-store
  namespace: default
spec:
  deploymentPipelineRef:
    name: default
  type:                                     # required + immutable
    kind: ClusterProjectType
    name: standard-project
  parameters:
    tier: premium
```

The Project controller cuts an immutable `ProjectRelease` named `online-store-{hash}` and records it on `status.latestRelease`. Deploy / promote is entirely a **ProjectReleaseBinding** operation — one binding per environment, **client-created, never controller-created** (so a project only deploys to the environments you make bindings for):

```yaml
apiVersion: openchoreo.dev/v1alpha1
kind: ProjectReleaseBinding
metadata:
  name: online-store-production            # convention: {project}-{environment}
  namespace: default
spec:
  owner:
    projectName: online-store              # immutable
  environment: production                  # immutable
  projectRelease: online-store-a1b2c3d4    # the pin; advance to promote
  environmentConfigs:
    cpuQuota: "16"
```

**One-time pin seeding = the deploy/promote model.** A binding created with `spec.projectRelease` **unset** is seeded **once** by the Project controller with the project's latest release, then no controller ever touches it again. Advancing the pin is always an explicit action — that is promotion. (A pin-less binding with no release yet stays `Synced=False, Reason=ProjectReleaseNotSet` until one is cut.) Under server-side apply / GitOps, omitting the field never conflicts with the one-time seeding, so "let the platform seed the first env" and "manage promotion pins in Git" coexist.

Surfaces:

- **`occ`** — `occ project scaffold online-store --clusterprojecttype standard-project` emits the Project manifest (parameters from the type's schema: required as placeholders, optional as commented examples) plus **one ProjectReleaseBinding per pipeline environment** (`--no-bindings` opts out; `--projecttype` for the namespaced kind; `--deployment-pipeline` defaults to `default`). `occ project deploy online-store` ensures a binding for the lowest pipeline environment (pin left unset → controller seeds it); `occ project deploy online-store --to staging [--set key=value]` promotes the target binding to the source environment's pinned release, merging `--set` into `environmentConfigs`.
- **Backstage** — Releases view + per-environment Promote.
- **kubectl / GitOps** — promotion is a one-field patch of `spec.projectRelease`; rollback is the same operation pointing at an older release (releases are immutable and kept).

Because the binding owns the cell namespace, **component / resource deployments to an environment wait for its ProjectReleaseBinding to converge** before they land.

---

## 5. Defaults that ship

A **`default` ClusterProjectType** ships with standard installs — it provisions **only** the cell namespace (its `environmentConfigs` accepts `namespaceLabels` / `namespaceAnnotations` maps, `oc_merge`d onto the namespace). Projects created through the **Backstage UI, the OpenChoreo API, or `occ project scaffold`** default to it when no type is given. **Projects applied directly with `kubectl` must set `spec.type` explicitly** — the field is required on the CRD with no server-side default for the raw-apply path.

Use the `default` type as the reference shape for a minimal ProjectType, and author richer ones (quotas, default-deny egress, RBAC, image-pull secrets) when a tenant needs guardrails beyond a bare namespace.

---

## 6. Verification

After authoring a ProjectType, walk the chain:

1. **Type accepted** — `get_project_type` (with `scope`) returns the spec. CEL parse errors and the missing-Namespace-in-resources shape surface here or at first render.
2. **Schema discoverable** — `get_project_type_schema` returns the `parameters` schema (what the project author fills in).
3. **A test Project cuts a release** — create a `Project` with `spec.type` pointing at the new type; `Project.status.latestRelease.name` (`{project}-{hash}`) populates within a reconcile.
4. **A test binding renders** — create a `ProjectReleaseBinding` for one environment; it should reach `Synced=True`, `NamespaceReady=True`, `ResourcesReady=True`, `Ready=True`, and surface the owned namespace on `status.namespace` (`dp-{ns}-{project}-{env}-{hash}`).
5. **Data-plane objects exist** — on the data plane, the cell namespace and the rendered quota / policy objects are present.

### Common `Synced=False` reasons on the binding

- `NamespaceMissing` — rendered output lacks the mandated `v1/Namespace` named `${metadata.namespace}` (missing entry, or an `includeWhen` suppressed it). Declare it, unguarded.
- `ProjectReleaseNotSet` — the binding has no pin yet and no release exists to seed from.
- `ProjectReleaseNotFound` — the pin points at a release that doesn't exist.
- `InvalidReleaseConfiguration` / `RenderingFailed` — a CEL eval or schema-validation error (bad `environmentConfigs`, a failing `validations` rule); the condition message names it.
- `EnvironmentNotFound` / `DataPlaneNotFound` / `ProjectNotFound` — the named environment / plane / project is missing.

`ResourcesReady=False` (`ResourcesProgressing` / `ResourcesDegraded` / `ResourceApplyFailed`) tracks the applied manifests' health on the data plane — drop to `kubectl` there.

### `kubectl` quick reference

```bash
kubectl get clusterprojecttype <name> -o yaml            # or: projecttype <name> -n <ns>
kubectl get projectrelease -n <ns> -l openchoreo.dev/project=<project>
kubectl get projectreleasebinding -n <ns> -o wide        # short name: prb
```
