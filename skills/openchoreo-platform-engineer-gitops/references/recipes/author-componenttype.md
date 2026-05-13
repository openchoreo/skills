# Recipe — Author a (Cluster)ComponentType via Git

Define a deployment template — workload kind, parameter schema, resource templates (CEL), validation rules, allow-lists for traits / workflows. Commit, PR, reconcile.

Tweaking an existing ComponentType uses the same recipe — edit the file, commit, Flux re-applies the full spec.

## Scope decision

| Scope | When | Path |
| --- | --- | --- |
| `ClusterComponentType` (default) | Visible to every namespace — platform-wide. | `platform-shared/component-types/<name>.yaml` |
| `ComponentType` (namespace-scoped) | Tenant isolation, stricter validation, gradual rollout before promoting. | `namespaces/<ns>/platform/component-types/<name>.yaml` |

**Scope rule.** `ClusterComponentType` may only reference `ClusterTrait` / `ClusterWorkflow` in allow-lists. Namespace-scoped `ComponentType` may reference both. Mismatched refs fail at admission.

## Steps

### 1. Pick a `workloadType` (immutable after creation)

- `deployment` — long-running with optional endpoints
- `statefulset` — stateful, ordered
- `cronjob` — periodic
- `job` — one-shot
- `proxy` — no default ships for this

### 2. Source the shape

Pick one per [`../authoring.md`](../authoring.md) *Shape-lookup*:

- **Full schema** — `./scripts/fetch-page.sh --exact --title "ClusterComponentType"` (or `"ComponentType"`).
- **Vanilla default** — fetch `service` / `webapp` / `worker` / `scheduled-task` from `samples/getting-started/component-types/` (URLs in `../authoring.md`).
- **Extra shape** — fetch `database` / `message-broker` from `sample-gitops` (URLs in `../authoring.md`).

If sourcing one scope but the user wants the other, apply the conversion in `../authoring.md` *Cluster ↔ namespace scope*.

### 3. Compose

Five load-bearing fields:

- **`workloadType`** — primary kind. Exactly one `resources[].id` must match this string.
- **`parameters.openAPIV3Schema`** — fields developers fill on `Component.spec.parameters`. Required unless a `default` is set.
- **`environmentConfigs.openAPIV3Schema`** — fields per `ReleaseBinding.spec.componentTypeEnvironmentConfigs` (replicas, resources, imagePullPolicy — anything per-env).
- **`resources[]`** — K8s resource templates with CEL. `id`, `template`, optional `includeWhen` / `forEach` / `var`. CEL context: [`../cel.md`](../cel.md) §5.
- **`validations[]`** — CEL expressions checked at admission for cross-field invariants (`size(workload.endpoints) > 0`).

Plus allow-lists:

- `allowedWorkflows[]` — which CI workflows developers may attach. Empty = none.
- `allowedTraits[]` — which traits may attach.

Skeleton:

```yaml
apiVersion: openchoreo.dev/v1alpha1
kind: ClusterComponentType
metadata:
  name: backend-service
spec:
  workloadType: deployment
  allowedWorkflows:
    - kind: ClusterWorkflow
      name: docker-gitops-release
    - kind: ClusterWorkflow
      name: google-cloud-buildpacks-gitops-release
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

For the full `resources[]` body — HTTPRoute fan-out, ConfigMap-per-container, ExternalSecret patches — copy from `sample-gitops` (`database.yaml`, `service.yaml`, `webapp.yaml`).

### 4. Commit + verify

Branch `platform/componenttype-<name>-<ts>`, message `"platform: add <ClusterComponentType|ComponentType> <name>"`. Canonical flow in [`../authoring.md`](../authoring.md) *Git workflow*. After merge:

```bash
flux get kustomizations -A
occ clustercomponenttype get <name>            # or occ componenttype get <name> -n <ns>
```

### 5. Smoke test

Have a developer create a Component:

```yaml
spec:
  componentType:
    kind: ClusterComponentType
    name: deployment/backend-service
  parameters:
    port: 9090
```

`WorkflowNotAllowed` / `TraitNotAllowed` on the Component means the allow-lists need expanding (or the developer's choice is wrong).

## Updating an existing ComponentType

Flux re-applies the full file every reconcile. **Anything not in the file is removed.** Don't half-edit.

## Variants

**Namespace-scoped tenancy** — same shape, `kind: ComponentType`, set `metadata.namespace`, path `namespaces/<ns>/platform/component-types/`. Component references it with `componentType.kind: ComponentType`.

**Marketplace pattern** — multiple ComponentTypes targeting the same `workloadType` with different defaults / validations (`service-strict`, `service-permissive`). Each is a separate file.

## Gotchas

- **`workloadType` is immutable.** Delete + recreate to change.
- **`resources[].id` of the primary workload must equal `workloadType`.** `workloadType: deployment` → exactly one `id: deployment`.
- **Don't hardcode `metadata.namespace` in templates.** Use `${metadata.namespace}` (CEL). Webhook rejects literal namespace strings.
- **`ClusterComponentType` may only reference `ClusterTrait` / `ClusterWorkflow`.** Mixing scopes fails validation.
- **`allowedWorkflows[]` must point at GitOps-compatible Workflows.** The vanilla CI workflows from `samples/getting-started/ci-workflows/` write the `Workload` to the cluster directly — Flux reverts. Use the GitOps variants (`docker-gitops-release` etc.) — see [`../authoring.md`](../authoring.md) *Vanilla CI workflows aren't GitOps-compatible*.
- **Required-by-default in JSON Schema.** Every property is required unless it has `default`. Use object-level `default: {}` on container objects so adding a required nested field doesn't silently break every existing Component.
- **CEL context.** `parameters` / `environmentConfigs` always available; `workload` / `configurations` / `dependencies` / `dataplane` / `gateway` in scope for `resources[]` and `validations[]`. See [`../cel.md`](../cel.md) §5.
- **`metadata.namespace`:** cluster-scoped CRDs reject it; namespace-scoped CRDs require it.
