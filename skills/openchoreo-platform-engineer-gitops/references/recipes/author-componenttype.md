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
- **Default for inspiration** — `./scripts/extract-resources.sh defaults --kind ClusterComponentType --name <service|web-application|worker|scheduled-task>`.
- **What's installed on the live cluster** — `occ clustercomponenttype get <name>` / `occ componenttype get <name> -n <ns>`.
- **What else exists in the ecosystem** — <https://openchoreo.dev/ecosystem/component-types.md> lists community CCTs (Agent Sandbox, WSO2 Micro Integrator, etc.) with source URLs.

If sourcing one scope but the user wants the other, apply the conversion in `../authoring.md` *Cluster ↔ namespace scope*.

### 3. Compose

Five load-bearing fields:

- **`workloadType`** — primary kind. Exactly one `resources[].id` must match this string.
- **`parameters.openAPIV3Schema`** — fields developers fill on `Component.spec.parameters`. Required unless a `default` is set.
- **`environmentConfigs.openAPIV3Schema`** — fields per `ReleaseBinding.spec.componentTypeEnvironmentConfigs` (replicas, resources, imagePullPolicy — anything per-env).
- **`resources[]`** — K8s resource templates with CEL. `id`, `template`, optional `includeWhen` / `forEach` / `var`. CEL context: [`../cel.md`](../cel.md) 5.
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

For the full `resources[]` body — HTTPRoute fan-out, ConfigMap-per-container, ExternalSecret patches — start from a default extracted via `./scripts/extract-resources.sh defaults --kind ClusterComponentType --name <service|web-application|worker|scheduled-task>` and adapt. Whatever you author, name objects and label pods per *Release-line-safe names and pod labels* below.

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

## Release-line-safe names and pod labels

A component's **release lines** (v1.4+; the `ReleaseLine` in [`../concepts.md`](../concepts.md) *Resource hierarchy*) all render into the same project namespace through the same ComponentType and Traits. Author every type so that each line gets its own objects. Otherwise, adding a line fails its ReleaseBinding with `ReleaseLineNameCollision` or `ReleaseLinePodLabelOverlap`, and the line doesn't deploy:

- **Per-environment objects** (Deployment, ConfigMaps, PVCs, anything in a `forEach`): name from `${metadata.name}`. It's already unique per line and environment.
- **Component-level names** (Service, HTTPRoute names, route path prefixes, `backendRefs`, the component part of gateway hostnames): use `${metadata.componentLineName}`. On the main line it's the component name, so existing components keep their names. On a release line it's `{component}-{line}-{hash}`. The shipped defaults write it as `metadata.releaseLineName == "" ? metadata.componentName : metadata.componentLineName`, which renders the same.
- **Pod template labels** are `${metadata.podSelectors}` and nothing from `metadata.labels`, whether in the ComponentType or in a Trait patch. `metadata.labels` carries `openchoreo.dev/component-uid` on every line, and that's the label the main line's selectors match. Add custom pod labels with `oc_merge(metadata.podSelectors, {...})`.

```yaml
- id: service
  template:
    apiVersion: v1
    kind: Service
    metadata:
      name: ${metadata.componentLineName}
      namespace: ${metadata.namespace}
    spec:
      selector: ${metadata.podSelectors}
      ports: ${workload.toServicePorts()}
```

**Version gate:** `metadata.componentLineName` and `metadata.releaseLineName` exist on v1.4+ only, which has the `releaselines.openchoreo.dev` CRD (`kubectl get crd releaselines.openchoreo.dev`). Against an older cluster, use `metadata.componentName` instead. A default extracted with `OCC_TAG` pinned to an older tag already does. The `metadata.name` and pod-label rules hold on every version.

## Variants

**Namespace-scoped tenancy** — same shape, `kind: ComponentType`, set `metadata.namespace`, path `namespaces/<ns>/platform/component-types/`. Component references it with `componentType.kind: ComponentType`.

**Marketplace pattern** — multiple ComponentTypes targeting the same `workloadType` with different defaults / validations (`service-strict`, `service-permissive`). Each is a separate file.

## Gotchas

- **`workloadType` is immutable.** Delete + recreate to change.
- **`resources[].id` of the primary workload must equal `workloadType`.** `workloadType: deployment` → exactly one `id: deployment`.
- **Don't hardcode `metadata.namespace` in templates.** Use `${metadata.namespace}` (CEL). Webhook rejects literal namespace strings.
- **Names built only from `metadata.componentName` break release lines.** They collide as soon as a component adds a line (`ReleaseLineNameCollision`). Use `metadata.name` / `metadata.componentLineName`, and label pods with `metadata.podSelectors` only. See *Release-line-safe names and pod labels*.
- **`ClusterComponentType` may only reference `ClusterTrait` / `ClusterWorkflow`.** Mixing scopes fails validation.
- **`allowedWorkflows[]` must point at GitOps-compatible Workflows.** The vanilla CI workflows in `samples/getting-started/all.yaml` (`dockerfile-builder` etc.) write the `Workload` to the cluster directly — Flux reverts. Use the GitOps variants (`docker-gitops-release` etc.) discoverable via `./scripts/extract-resources.sh gitops-workflows --list`. See [`../authoring.md`](../authoring.md) *Vanilla CI workflows aren't GitOps-compatible*.
- **Required-by-default in JSON Schema.** Every property is required unless it has `default`. Use object-level `default: {}` on container objects so adding a required nested field doesn't silently break every existing Component.
- **CEL context.** `parameters` / `environmentConfigs` always available; `workload` / `configurations` / `dependencies` / `dataplane` / `gateway` in scope for `resources[]` and `validations[]`. See [`../cel.md`](../cel.md) 5.
- **`metadata.namespace`:** cluster-scoped CRDs reject it; namespace-scoped CRDs require it.
