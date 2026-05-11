# Author a Trait

Define a reusable cross-cutting capability — alert rules, ingress patterns, sidecar injection, autoscaling, persistent volumes — that developers attach to a Component without rewriting the ComponentType. Two mechanisms: `creates` (new resources) and `patches` (mutations to ComponentType-generated resources). MCP-driven.

## When to use

- A capability needs to be reusable across many Components (don't bake it into every ComponentType)
- Developers should opt in per-component (a sidecar that only some services need; persistent storage only for stateful ones)
- The capability is orthogonal to the workload kind (alerts attach to Deployments, StatefulSets, and CronJobs equally — write one Trait, list it in `allowedTraits` on each ComponentType)

For per-environment differences (e.g. larger PVC in prod), set `environmentConfigs` on the Trait — developers override values per environment via `ReleaseBinding.spec.traitEnvironmentConfigs[<instanceName>]`.

## Prerequisites

1. The control-plane MCP server is configured (`list_namespaces` returns).
2. You've decided cluster-scoped vs namespace-scoped (see **Variants**). Default is `ClusterTrait`.
3. You know which ComponentTypes will list the trait in `allowedTraits` — the trait is unusable until at least one type allows it. Cross-scope rules apply: a `ClusterComponentType` may only allow `ClusterTrait`s.
4. To learn real-world patterns (parameter schemas, environment-config overrides, `creates[]` vs `patches[]`, CEL in templates), inspect an existing trait on the cluster: `get_cluster_trait name: observability-alert-rule` (or whichever traits the platform ships). The returned spec shows production patterns to adapt.

## Recipe

### 1. Sanity-check what already exists

```text
list_cluster_traits
```

Don't duplicate. If a similar trait exists, prefer extending it (`update_*`) over creating a sibling — multiple alert traits with overlapping behavior cause noise.

### 2. Fetch the creation schema

```text
get_trait_creation_schema
```

Returns the schema for the `spec` body — `parameters`, `environmentConfigs`, `validations` (namespace-scoped only), `creates[]`, `patches[]`.

### 3. Decide: `creates`, `patches`, or both

| Mechanism | Use when |
|---|---|
| **`creates[]`** | The trait introduces a *new* Kubernetes resource alongside the component — PVC, ExternalSecret, ServiceMonitor, Ingress, ObservabilityAlertRule |
| **`patches[]`** | The trait *modifies* a resource the ComponentType already produces — inject a sidecar, add a volume mount, append a label, set an annotation |
| **Both** | Common for capabilities that need both — a persistent-volume trait creates the PVC (`creates`) and adds the volume + volume-mount to the existing Deployment (`patches`) |

See [`../component-types-and-traits.md`](../component-types-and-traits.md) §3 for the full `patches` operation set (JSON Patch + array filtering + CEL paths and values), and [`../cel.md`](../cel.md) for context variables (note `resource` is only available inside a patch's `where` filter).

### 4. Compose the spec

```yaml
create_cluster_trait
  name: persistent-volume
  spec:
    parameters:
      openAPIV3Schema:
        type: object
        properties:
          volumeName: { type: string }
          mountPath:  { type: string }
          containerName:
            type: string
            default: main
        required: [volumeName, mountPath]
    environmentConfigs:
      openAPIV3Schema:
        type: object
        properties:
          size:
            type: string
            default: "10Gi"
          storageClass:
            type: string
            default: standard
    creates:
      - targetPlane: dataplane
        template:
          apiVersion: v1
          kind: PersistentVolumeClaim
          metadata:
            name: ${metadata.name}-${trait.instanceName}
            namespace: ${metadata.namespace}
          spec:
            accessModes: [ReadWriteOnce]
            storageClassName: ${environmentConfigs.storageClass}
            resources:
              requests:
                storage: ${environmentConfigs.size}
    patches:
      - target:
          kind: Deployment
          group: apps
          version: v1
        operations:
          - op: add
            path: /spec/template/spec/volumes/-
            value:
              name: ${parameters.volumeName}
              persistentVolumeClaim:
                claimName: ${metadata.name}-${trait.instanceName}
          - op: add
            path: /spec/template/spec/containers[?(@.name=='${parameters.containerName}')]/volumeMounts/-
            value:
              name: ${parameters.volumeName}
              mountPath: ${parameters.mountPath}
```

Note the use of `${trait.instanceName}` in resource names — that's how the same trait can attach multiple times to one component without name collisions (one PVC per instance). See [`../component-types-and-traits.md`](../component-types-and-traits.md) §3 *Trait `instanceName`*.

### 5. List the trait on at least one ComponentType

A trait is unusable until some ComponentType lists it in `allowedTraits`. Either edit an existing type (`get_cluster_component_type` → modify → `update_cluster_component_type`), or include the trait in the type's `allowedTraits` from the start.

### 6. Verify

```yaml
get_cluster_trait
  name: persistent-volume
```

Then attach it to a test component and check rendering:

```yaml
create_component
  componentType: { kind: ClusterComponentType, name: deployment/web-service }
  traits:
    - kind: ClusterTrait
      name: persistent-volume
      instanceName: data-storage
      parameters: { volumeName: data, mountPath: /var/data }
get_component
  component_name: <test>     # check status.conditions for trait rendering errors
```

## Recipe — updating an existing Trait

`update_*` is full-spec replacement:

```yaml
get_cluster_trait
  name: persistent-volume
# Modify locally
update_cluster_trait
  name: persistent-volume
  spec: <complete modified spec>
```

For one-line patch / template edits, `kubectl apply -f` is often cleaner.

## Variants

### Cluster-scoped `ClusterTrait` (the default)

Visible across every namespace. Used by every `ClusterComponentType` that lists it. Most platform-wide capabilities live here.

### Namespace-scoped `Trait`

```yaml
create_trait
  namespace_name: acme
  name: tenant-only-sidecar
  spec: { ... }      # same shape as ClusterTrait
```

Use cases: tenant teams that need their own sidecar injection rules, regulated tenants with mandatory observability shims, gradual rollout of a new trait shape before promoting to a `ClusterTrait`.

> **`ClusterTrait` does NOT support `spec.validations`.** Only namespace-scoped `Trait` does. The cluster-scoped variant rejects validations at create / update time. If you need validation logic on a cluster-scoped capability, push the rule into the `parameters.openAPIV3Schema` (constraints, enums, patterns, required) — schema validation is supported on both.
>
> **Scope rule.** A `ClusterComponentType` may only reference `ClusterTrait` in `allowedTraits`. A namespace-scoped `ComponentType` may reference both `Trait` and `ClusterTrait`.

## Gotchas

- **Full-spec replacement on update.** `get_*` first; missing fields are deleted. For one-line patch tweaks, `kubectl apply -f` against an edited YAML often produces a cleaner diff.
- **`ClusterTrait` rejects `validations`.** Move logic to schema-level constraints, or namespace-scope the trait if validations are essential.
- **Per-component `instanceName` must be unique** within that Component's `traits[]` list — that's a developer concern, but Trait templates / patches must use `${trait.instanceName}` in resource names so multi-attach works (e.g. two PVCs with different mount paths).
- **Per-environment trait config overrides happen via `ReleaseBinding.spec.traitEnvironmentConfigs[<instanceName>]` — not in the trait itself.** The trait declares the *shape* (`environmentConfigs.openAPIV3Schema`); the developer fills in per-env values on the binding.
- **Patch targeting must be exact.** `target.kind`, `target.group`, `target.version` are required. For core API resources (Service, ConfigMap, Secret), `group: ""`. JSON Patch array filters support **single-field equality only** — no `&&`, no `contains`, no nested existence checks.
- **`patches[].where` runs against the candidate resource** (the `resource` variable). Use it to scope a patch to specific resources — e.g. only the Deployment that has more than one container. Note `resource` is *only* available in `where`, not in `operations[]`.
- **Patch path escaping uses JSON Pointer**: `/` in a key → `~1`, `~` in a key → `~0`. Most often hits Kubernetes annotation keys (`kubernetes.io~1ingress-class`).
- **One trait per concern.** Don't fold ingress, autoscaling, and alerts into one `mega-trait` — composability breaks. Developers attach one trait per capability with its own `instanceName`.
- **Compose, don't patch ComponentType internals.** A trait that depends on the ComponentType producing a specific named resource is fragile. Where possible, target by `kind`/`group`/`version` rather than by name.

## Related

- [`../component-types-and-traits.md`](../component-types-and-traits.md) — full topical reference (Trait skeleton, `creates`, `patches`, JSON Patch operations, array filtering, escaping, common patterns)
- [`../cel.md`](../cel.md) — CEL syntax, the `resource` variable in `patches[].where`, helper functions, context-variable availability matrix
- [`./author-a-componenttype.md`](./author-a-componenttype.md) — the type that lists this trait in `allowedTraits`
