# Author a ComponentType

Define a new deployment template — workload kind, parameter schema, resource templates, validation rules, and trait / workflow allow-lists — so developers can `create_component componentType: <workloadType>/<name>` against it. MCP-driven; `kubectl apply -f` is a fallback for big YAML edits.

## When to use

- A new workload pattern not served by built-ins (e.g. an org-specific deploy contract: sidecarred service, blue-green rollout, custom proxy shape)
- Existing types are too permissive — you want a tighter `allowedWorkflows`, narrower `allowedTraits`, or stricter `validations`
- You need per-environment parameter overrides (`environmentConfigs`) the built-ins don't model

For **tweaking** an existing type (CEL fix, one new validation rule), prefer `kubectl apply -f` against the live YAML — `update_*` is full-spec replacement and noisy for small edits.

## Prerequisites

1. The control-plane MCP server is configured and reachable (`list_namespaces` returns).
2. You've decided cluster-scoped vs namespace-scoped (see **Variants** below). Default is `ClusterComponentType` — use namespace-scoped only when an org tenancy boundary requires it.
3. You've picked a `workloadType` from `deployment` / `statefulset` / `cronjob` / `job` / `proxy`. **Immutable after creation**, so pick deliberately.
4. To learn real-world patterns (CEL templates, HTTPRoute fan-out, ExternalSecret patches) without authoring from scratch, inspect an existing ClusterComponentType on the cluster: `get_cluster_component_type cct_name: deployment/service` (or whichever the platform already ships). The returned `spec.resources[*].template` shows production patterns directly.

## Recipe

### 1. Sanity-check what already exists

```text
list_cluster_component_types
```

If a type with a similar name already exists, decide whether to extend it (`update_*`) or create a sibling. ComponentType names don't collide cross-scope (a namespace-scoped `ComponentType` named `service` doesn't conflict with `ClusterComponentType/service`), but UI / discovery can become confusing.

### 2. Fetch the creation schema

```text
get_cluster_component_type_creation_schema
```

Returns the full JSON schema for the `spec` body — `workloadType`, `allowedWorkflows`, `allowedTraits`, `parameters`, `environmentConfigs`, `validations`, `resources[]`. Use this to shape the spec payload, not memory.

### 3. Compose the spec

Five fields drive almost everything:

- **`workloadType`** — primary kind. The entry in `resources[]` whose `id` matches this string is the *primary workload*. If `workloadType: deployment`, exactly one `resources[].id: deployment` is required.
- **`parameters.openAPIV3Schema`** — what developers fill in on `Component.spec.parameters`. **Required-by-default** unless a field has a `default`. See [`../component-types-and-traits.md`](../component-types-and-traits.md) §4 for the full schema syntax.
- **`environmentConfigs.openAPIV3Schema`** — per-environment values from `ReleaseBinding.spec.componentTypeEnvironmentConfigs`. Same syntax. Use this for replicas, resource limits — anything that varies between dev / staging / prod.
- **`resources[]`** — Kubernetes resource templates with CEL expressions. `id`, `template`, optional `includeWhen` / `forEach` / `var`. CEL contexts available here are documented in [`../cel.md`](../cel.md) §5 (look at the *availability matrix*).
- **`validations[]`** — CEL expressions that must evaluate true at admission time. Use to enforce cross-field invariants the schema can't (e.g. "production needs ≥ 2 replicas").

`allowedWorkflows` and `allowedTraits` gate which CI workflows and traits developers can attach. **Must list at least one workflow** if you expect source-build to be possible, and at least one trait if developers should attach any.

### 4. Create the type

```yaml
create_cluster_component_type
  name: backend-service
  spec:
    workloadType: deployment
    allowedWorkflows:
      - kind: ClusterWorkflow
        name: dockerfile-builder
      - kind: ClusterWorkflow
        name: gcp-buildpacks-builder
    allowedTraits:
      - kind: ClusterTrait
        name: observability-alert-rule
    parameters:
      openAPIV3Schema:
        type: object
        properties:
          port:
            type: integer
            default: 8080
            minimum: 1
            maximum: 65535
    environmentConfigs:
      openAPIV3Schema:
        type: object
        properties:
          replicas: { type: integer, default: 1, minimum: 0 }
          resources:
            type: object
            default: {}
            properties:
              cpu:    { type: string, default: "100m" }
              memory: { type: string, default: "256Mi" }
    validations:
      - rule: ${size(workload.endpoints) > 0}
        message: "Service components must expose at least one endpoint"
    resources:
      - id: deployment
        template: { ... }
      - id: service
        includeWhen: ${size(workload.endpoints) > 0}
        template: { ... }
```

For the full `resources[]` body — including HTTPRoute fan-out, ConfigMap-per-container, ExternalSecret patterns — inspect what the platform already ships: `get_cluster_component_type cct_name: deployment/service` (or `deployment/web-application`, `deployment/worker`, `cronjob/scheduled-task`). The returned spec shows production patterns to adapt.

### 5. Confirm and exercise

```yaml
get_cluster_component_type
  cct_name: backend-service
```

Check `status.conditions[]` for any rendering / validation errors. Then try a Component against it from the developer side:

```yaml
create_component
  componentType:
    kind: ClusterComponentType
    name: deployment/backend-service
  parameters: { ... }
```

A `WorkflowNotAllowed` / `TraitNotAllowed` failure on the component means your `allowedWorkflows` / `allowedTraits` need expanding — or the developer's choice is wrong.

## Recipe — updating an existing ComponentType

`update_*` is **full-spec replacement** — omitted fields are deleted. Always read first:

```yaml
get_cluster_component_type
  cct_name: backend-service
# Modify the spec locally (e.g. add a validation rule, tighten allowedWorkflows)
update_cluster_component_type
  name: backend-service
  spec: <the entire modified spec>
```

For one-line edits to a CEL template or a single validation rule, `kubectl edit clustercomponenttype backend-service` (or `kubectl apply -f` against an edited YAML) is often easier and produces a cleaner diff than the MCP full-replacement update. Both paths produce the same end state.

## Variants

### Namespace-scoped `ComponentType`

If a single tenant team needs its own deployment template — different validation rules, different `allowedTraits`, different `resources[]` — author a namespace-scoped `ComponentType` instead:

```yaml
create_component_type
  namespace_name: acme
  name: tenant-service
  spec: { ... }      # same shape as ClusterComponentType
```

Use cases: regulated tenants needing stricter limits, per-team experimental shapes, and gradual rollout (build a new shape namespace-scoped, then promote to `ClusterComponentType` once stable).

> **Scope rule.** A `ClusterComponentType` may only reference `ClusterTrait` and `ClusterWorkflow` in its allow-lists. A namespace-scoped `ComponentType` may reference both cluster-scoped and namespace-scoped variants. Mismatched references fail validation at create time.

### Cluster-scoped variant (the default)

`create_cluster_component_type` — what most platforms ship. Visible to all namespaces. Used in `Component.spec.componentType.kind: ClusterComponentType`.

## Gotchas

- **`update_*` is full-spec replacement.** `get_*` first, modify locally, send the complete spec back. Omitting a field deletes it. For one-line tweaks, `kubectl apply -f` may be easier.
- **`workloadType` is immutable after creation.** Switching from `deployment` to `statefulset` requires delete + recreate (and updating any Components that reference it).
- **`resources[].id` of the primary workload must equal `workloadType`.** `workloadType: deployment` → exactly one entry with `id: deployment`. The platform uses this convention to find the workload.
- **Don't hardcode `metadata.namespace` in resource templates.** Use `${metadata.namespace}` (the platform-resolved target namespace). The webhook rejects literal namespace strings (admission rule v1.0.0-rc.2+).
- **`ClusterComponentType` may only reference `ClusterTrait` / `ClusterWorkflow`.** A `ClusterComponentType` listing a namespace-scoped `Trait` in `allowedTraits` will fail.
- **`ClusterComponentType` manifests must not include `metadata.namespace`.** Cluster-scoped CRDs reject it.
- **Required-by-default.** Every property in `parameters` and `environmentConfigs` is required unless it has `default`. Object-level defaults (`default: {}`) matter — without them, adding a required nested field silently breaks every existing Component.
- **Validation rule context varies.** `parameters` and `environmentConfigs` are always available; `workload`, `configurations`, `dependencies`, `dataplane`, `gateway` are also in scope for ComponentType validations. See [`../cel.md`](../cel.md) §5.
- **Trait `instanceName` collisions are *per-component*, not platform-wide.** That's a developer concern — but if your validations check for it, scope the rule to a single component's traits.

## Related

- [`../component-types-and-traits.md`](../component-types-and-traits.md) — full topical reference (concepts, schema syntax, validation rules, patterns, verification flow)
- [`../cel.md`](../cel.md) — CEL syntax, built-in functions, context-variable availability matrix
- [`./author-a-trait.md`](./author-a-trait.md) — for the trait surface that this type's `allowedTraits` will reference
- [`./author-a-ci-workflow.md`](./author-a-ci-workflow.md) — for the workflow surface that this type's `allowedWorkflows` will reference
