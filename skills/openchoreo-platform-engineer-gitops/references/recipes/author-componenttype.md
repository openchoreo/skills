# Recipe — Author a (Cluster)ComponentType via Git

Define a deployment template — workload kind, parameter schema, resource templates (CEL), validation rules, allow-lists for traits / workflows. Commit, PR, reconcile.

For one-line tweaks on an existing ComponentType, the same recipe applies — open the file, edit, commit. Flux re-applies the full file every reconcile.

## Scope decision

| Scope                             | When                                                                                                  | File path                                                       |
| --------------------------------- | ----------------------------------------------------------------------------------------------------- | --------------------------------------------------------------- |
| `ClusterComponentType` (default)  | Should be visible to every namespace — platform-wide.                                                 | `platform-shared/component-types/<name>.yaml`                   |
| `ComponentType` (namespace-scoped) | Tenant isolation — stricter validations, narrower `allowedTraits`, gradual rollout before promoting. | `namespaces/<ns>/platform/component-types/<name>.yaml`          |

**Scope rule.** `ClusterComponentType` may only reference `ClusterTrait` and `ClusterWorkflow` in its allow-lists. Namespace-scoped `ComponentType` may reference both cluster- and namespace-scoped variants. Mismatched references fail validation at admission.

## Steps

### 1. Decide the workload type

Immutable after creation — pick deliberately. One of:

- `deployment` — long-running with optional endpoints
- `statefulset` — stateful, ordered
- `cronjob` — periodic
- `job` — one-shot
- `proxy` — proxy-shaped (no default ComponentType ships for this)

### 2. Source the shape

Pick one per the shape-lookup decision table in [`../authoring.md`](../authoring.md):

- **Live cluster** — `occ clustercomponenttype get <name>` (or `occ componenttype get <name> -n <ns>`). Strip `status:` / `metadata.managedFields:` etc.
- **Vanilla default** — WebFetch from `samples/getting-started/component-types/`:
  - `service`, `webapp`, `worker`, `scheduled-task` at `https://raw.githubusercontent.com/openchoreo/openchoreo/main/samples/getting-started/component-types/<name>.yaml`
- **Extra shape** — WebFetch from `sample-gitops`:
  - `database`, `message-broker` at `https://raw.githubusercontent.com/openchoreo/sample-gitops/main/namespaces/default/platform/component-types/<name>.yaml`
- **API reference** for novel shapes — `https://openchoreo.dev/docs/reference/api/platform/clustercomponenttype.md` (cluster) or `.../componenttype.md` (namespace).

> If sourcing from the vanilla defaults (cluster-scoped) or `sample-gitops` (namespace-scoped) and the user wants the other scope, apply the swap per [`../authoring.md`](../authoring.md) *Cluster ↔ namespace scope*.

### 3. Compose the spec

The five load-bearing fields:

- **`workloadType`** — primary kind. The entry in `resources[]` whose `id` matches this string is the *primary workload*. If `workloadType: deployment`, exactly one `resources[].id: deployment` is required.
- **`parameters.openAPIV3Schema`** — fields developers fill in on `Component.spec.parameters`. Required-by-default unless a field has a `default`. **Schema syntax**: <https://openchoreo.dev/docs/platform-engineer-guide/component-types/schema-syntax.md>.
- **`environmentConfigs.openAPIV3Schema`** — fields per `ReleaseBinding.spec.componentTypeEnvironmentConfigs`. Same syntax. Use for replicas, resource limits, image pull policy — anything that varies between dev / staging / prod.
- **`resources[]`** — Kubernetes resource templates with CEL expressions. `id`, `template`, optional `includeWhen` / `forEach` / `var`. CEL contexts available here are in [`../cel.md`](../cel.md) §5.
- **`validations[]`** — CEL expressions that must evaluate true at admission. Use for cross-field invariants the schema can't (`size(workload.endpoints) > 0`).

Plus the allow-lists:

- `allowedWorkflows[]` — which CI workflows developers may attach to a Component using this type. Empty = none allowed.
- `allowedTraits[]` — which traits may attach.

Skeleton for `ClusterComponentType`:

```yaml
# shape: https://openchoreo.dev/docs/reference/api/platform/clustercomponenttype.md (occ v1.0.x)
apiVersion: openchoreo.dev/v1alpha1
kind: ClusterComponentType
metadata:
  name: backend-service                  # no namespace — cluster-scoped
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

For the full `resources[]` body — HTTPRoute fan-out, ConfigMap-per-container, ExternalSecret patches — copy from `sample-gitops`'s `database.yaml` / `service.yaml` / `webapp.yaml`.

### 4. Save under the right path

| Kind                       | Path                                                          |
| -------------------------- | ------------------------------------------------------------- |
| `ClusterComponentType`     | `platform-shared/component-types/<name>.yaml`                 |
| `ComponentType` (ns-scoped) | `namespaces/<ns>/platform/component-types/<name>.yaml`        |

For namespace-scoped, **include `metadata.namespace: <ns>`**. For cluster-scoped, **omit `metadata.namespace`** — cluster CRDs reject it.

### 5. Commit, PR, reconcile

```bash
git checkout -b platform/componenttype-<name>-$(date +%Y%m%d-%H%M%S)
git add <file>
git status                                # show the user the diff
git commit -s -m "platform: add <ClusterComponentType|ComponentType> <name>"
git push origin HEAD
gh pr create --fill                       # only after user confirmation
```

After merge, walk the verification ladder:

```bash
flux get kustomizations -A
occ clustercomponenttype get <name>       # or occ componenttype get <name> -n <ns>
# status.conditions[] should be clean
```

### 6. Smoke test from the developer side

Have a developer (or use whatever application-side tooling is in play) create a Component against the new type:

```yaml
# In namespaces/<ns>/projects/<project>/components/<component>/component.yaml
apiVersion: openchoreo.dev/v1alpha1
kind: Component
spec:
  owner:
    projectName: <project>
  componentType:
    kind: ClusterComponentType            # or ComponentType (namespace-scoped)
    name: deployment/backend-service
  parameters:
    port: 9090
```

A `WorkflowNotAllowed` / `TraitNotAllowed` failure on the Component means the type's allow-lists need expanding — or the developer's choice is wrong.

## Updating an existing ComponentType

Edit the file in Git. Flux re-applies the full spec on the next reconcile — *all fields in the file become live; anything not in the file is removed*. Don't half-edit.

For the controller-side semantics: any imperative `update` against the API server is **full-spec replacement** (omitting a field deletes it). In GitOps mode you don't call `update` directly — you commit the new YAML and Flux applies the same replacement. The mental model is identical: the file in Git is the desired state, full stop.

## Variants

### Namespace-scoped tenancy

Same shape, different `kind` (`ComponentType`), different path (`namespaces/<ns>/platform/component-types/`), `metadata.namespace` set. Reference from `Component.spec.componentType.kind: ComponentType`.

Use cases: regulated tenants needing stricter validations, per-team experimental shapes, or rolling out a new shape namespace-scoped first and promoting to `ClusterComponentType` once stable.

### Building a "marketplace" pattern

Multiple ComponentTypes targeting the same `workloadType` but with different defaults / validations (e.g. `deployment/service-strict`, `deployment/service-permissive`). Each is a separate file. Developers pick at Component-creation time.

## Gotchas

- **`workloadType` is immutable.** Delete + recreate to change.
- **`resources[].id` of the primary workload must equal `workloadType`.** `workloadType: deployment` → exactly one entry with `id: deployment`. The platform uses this convention to find the workload.
- **Don't hardcode `metadata.namespace` in resource templates.** Use `${metadata.namespace}` (CEL-resolved to the target namespace per Component). The webhook rejects literal namespace strings.
- **`ClusterComponentType` may only reference `ClusterTrait` / `ClusterWorkflow`** in allow-lists. Including a namespace-scoped `Trait` fails validation. See [`../authoring.md`](../authoring.md) *Cluster ↔ namespace scope*.
- **`allowedWorkflows[]` must list GitOps-mode workflows in a GitOps repo.** The vanilla CI workflows (`dockerfile-builder` etc.) shipped in `samples/getting-started/` reference workflows that write the `Workload` directly to the cluster — Flux reverts them. If you copied a ComponentType from `samples/getting-started/`, **rewrite `allowedWorkflows[]`** to point at `docker-gitops-release` / `google-cloud-buildpacks-gitops-release` / `react-gitops-release`. See [`../authoring.md`](../authoring.md) *Vanilla CI workflows aren't GitOps-compatible*.
- **Required-by-default in JSON Schema.** Every property in `parameters` and `environmentConfigs` is required unless it has `default`. Object-level defaults (`default: {}`) matter — without them, adding a required nested field silently breaks every existing Component.
- **CEL context availability matters.** `parameters` and `environmentConfigs` are always available; `workload`, `configurations`, `dependencies`, `dataplane`, `gateway` are in scope for ComponentType `resources[]` and `validations[]`. See [`../cel.md`](../cel.md) §5.
- **Trait `instanceName` collisions are per-component, not platform-wide.** If your `validations` check for them, scope the rule to a single component's traits.
- **`metadata.namespace` rules:** cluster-scoped CRDs reject it; namespace-scoped CRDs require it.

## Related

- [`author-trait.md`](./author-trait.md) — the trait surface this type's `allowedTraits` references
- [`author-workflow.md`](./author-workflow.md) — the workflow surface this type's `allowedWorkflows` references
- [`../cel.md`](../cel.md) — CEL syntax + context-variable availability
- [`../authoring.md`](../authoring.md) — llms.txt, repo paths, commit / PR flow
