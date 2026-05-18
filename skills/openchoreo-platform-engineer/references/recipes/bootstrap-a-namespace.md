# Bootstrap a Namespace

Stand up a fresh control-plane namespace with the standard set of platform resources — Environments, a `DeploymentPipeline`, and a default `Project` — so developers in that namespace can immediately start authoring Components against the cluster-scoped `ClusterComponentType`s, `ClusterTrait`s, and `ClusterWorkflow`s. Fully MCP-driven.

## When to use

- Multi-tenant onboarding: a new team, a new product line, a new business unit gets its own namespace boundary
- Hard-isolation tenants (regulated workloads, security-sensitive teams) that need their own platform-resource overrides

> **Default to the `default` namespace** unless the user explicitly asks otherwise (per the SKILL.md guardrail). Creating a new namespace is a significant org boundary — explicitly **confirm with the user before running `create_namespace`**. Once created, the namespace is the unit of tenancy: cross-namespace component dependencies require gateway configuration and aren't casual.

## Prerequisites

1. The control-plane MCP server is configured (`list_namespaces` returns).
2. **At least one `DataPlane` (or `ClusterDataPlane`) registered.** Environments need a plane to point at. By default, OpenChoreo installs ship with `ClusterDataPlane/default`, visible across all namespaces — verify with `list_dataplanes` and `get_dataplane` (both with `scope: "cluster"`; `get_dataplane scope: cluster, name: default`). If it's missing, that's an install-side concern (handed off to `openchoreo-install`).
3. Cluster-scoped platform resources (`ClusterComponentType`, `ClusterTrait`, `ClusterWorkflow`) are already in place. New namespaces inherit them automatically — verify with `list_component_types`, `list_traits`, `list_workflows` (each with `scope: "cluster"`).
4. The user has explicitly confirmed they want a new namespace. Default behavior is to use `default`.
5. To see a complete bootstrap shape, inspect what the platform's `default` namespace has: `list_environments`, `list_deployment_pipelines`, `list_projects` against `default`. The returned resources show the standard dev / staging / prod layout you'll reproduce in the new namespace.

## Recipe

The standard sequence: namespace → environments → deployment pipeline → default project. Each later step depends on the earlier ones, so it's strictly sequential.

### 1. Create the namespace

```yaml
create_namespace
  name: acme
  display_name: Acme Inc                    # optional
  description: Acme product team tenancy    # optional
```

The MCP tool also applies the `openchoreo.dev/control-plane=true` label automatically (the controller filters discovery by this label). If you're going through `kubectl` instead, you must label the namespace yourself — see the doc walkthrough at <https://openchoreo.dev/docs/platform-engineer-guide/namespace-management/>.

### 2. Create environments

Bare minimum is one environment, but most teams want at least dev / staging / prod. Repeat per env:

```yaml
create_environment
  namespace_name: acme
  name: development
  data_plane_ref: default
  data_plane_ref_kind: ClusterDataPlane
  is_production: false

create_environment
  namespace_name: acme
  name: staging
  data_plane_ref: default
  data_plane_ref_kind: ClusterDataPlane
  is_production: false

create_environment
  namespace_name: acme
  name: production
  data_plane_ref: default
  data_plane_ref_kind: ClusterDataPlane
  is_production: true
```

For more on env / pipeline mechanics — including using a namespace-scoped `DataPlane` for hard-isolated tenants — see [`./create-an-environment-and-promotion-path.md`](./create-an-environment-and-promotion-path.md).

### 3. Create the deployment pipeline

```yaml
create_deployment_pipeline
  namespace_name: acme
  name: default
  promotion_paths:
    - source_environment_ref: development
      target_environment_refs: [{name: staging}]
    - source_environment_ref: staging
      target_environment_refs: [{name: production}]
```

### 4. Create the default project

```yaml
create_project
  namespace_name: acme
  name: default
  display_name: Default Project
  description: Default project for components in the acme namespace
  deployment_pipeline: default
```

> **Note the parameter name.** The MCP tool's parameter is `deployment_pipeline` (a string), **not** `deployment_pipeline_ref` — the API server constructs the object reference internally with `kind` defaulting to `DeploymentPipeline`.

### 5. Verify

```text
list_namespaces                                          # confirm acme appears
list_environments namespace_name: acme                   # 3 envs
list_deployment_pipelines namespace_name: acme           # 1 pipeline
list_projects namespace_name: acme                       # 1 project; check the entry's deploymentPipelineRef
```

For deeper inspection (no single-`Project` MCP get): `kubectl get project default -n acme -o yaml`.

Then have a developer create their first component in this namespace to confirm the cluster-scoped types are visible (the cluster-scoped `ClusterComponentType` / `ClusterTrait` / `ClusterWorkflow` resources are automatically inherited — no per-namespace copy needed unless you want isolation).

## Variants

### Namespace-private platform resources (for isolation)

If the new tenant needs their own deployment templates / capabilities / build pipelines — for example, stricter `validations`, custom `allowedTraits`, a private builder — author them as namespace-scoped variants right after the bootstrap:

- New namespace-scoped `ComponentType`: see [`./author-a-componenttype.md`](./author-a-componenttype.md) → *Variants: namespace-scoped*.
- New namespace-scoped `Trait`: see [`./author-a-trait.md`](./author-a-trait.md) → *Variants: namespace-scoped* (note: namespace-scoped `Trait` supports `validations`; `ClusterTrait` does not).
- New namespace-scoped `Workflow`: see [`./author-a-ci-workflow.md`](./author-a-ci-workflow.md) or [`./author-a-generic-workflow.md`](./author-a-generic-workflow.md) → *Variants: namespace-scoped*.

Namespace-scoped variants don't replace the cluster-scoped defaults — they sit alongside. Components in the namespace can reference either, but a `ClusterComponentType` may only reference `ClusterTrait` / `ClusterWorkflow` (cross-scope rule).

### Namespace-scoped DataPlane

For hard tenant isolation (dedicated cluster), register a namespace-scoped `DataPlane` first (kubectl), then reference it on `create_environment`:

```yaml
create_environment
  namespace_name: acme
  name: production
  data_plane_ref: acme-prod-plane
  data_plane_ref_kind: DataPlane             # namespace-scoped, not cluster
  is_production: true
```

Plane registration is install-side; if a namespace-scoped `DataPlane` doesn't exist, hand off to `openchoreo-install`.

### Bootstrap with extra envs

The standard trio (`development` / `staging` / `production`) is the common shape, but `qa` / `pre-production` / `perf` / `sandbox` are common additions. Add the env via `create_environment`, then update the pipeline's `promotion_paths` to include the new node — see [`./create-an-environment-and-promotion-path.md`](./create-an-environment-and-promotion-path.md) for the wiring.

## Gotchas

- **Always confirm with the user before `create_namespace`.** It's an organizational boundary, not a casual default. Per the SKILL.md guardrail: "Default to the `default` namespace. Always ask before creating a new namespace — it's an organisational boundary, not a casual default."
- **`create_project` parameter is `deployment_pipeline` (string), not `deployment_pipeline_ref`.** Easy to typo. The MCP tool wraps it as the object reference server-side.
- **Environments need a plane registered first.** If `data_plane_ref: default` doesn't resolve to an existing `ClusterDataPlane` (or namespace-scoped `DataPlane` if `data_plane_ref_kind: DataPlane`), `create_environment` fails. Verify with `list_dataplanes` (`scope: "cluster"`) before starting.
- **The namespace label `openchoreo.dev/control-plane=true` is required.** `create_namespace` via MCP applies it; raw `kubectl create namespace` does not, and the controller will skip un-labeled namespaces.
- **Rolling back a failed bootstrap.** Hard-delete via `kubectl delete namespace <name>` against the control plane (cascades to every OpenChoreo CR in the namespace) — destructive, confirm with the user.
- **Cluster-scoped platform resources are inherited automatically.** New namespaces don't need a copy of `ClusterComponentType` / `ClusterTrait` / `ClusterWorkflow` — they're visible by default. Only create namespace-scoped variants if you want isolation or overrides.
- **Don't bootstrap without at least one ComponentType / Trait / Workflow available.** The Project + Environments + Pipeline are useless if there's nothing for developers to deploy. Verify with `list_component_types` etc. (`scope: "cluster"`) before bootstrapping; if empty, that's an install-side concern (handed off to `openchoreo-install`).

## Related

- [`./create-an-environment-and-promotion-path.md`](./create-an-environment-and-promotion-path.md) — for adding new envs / paths after bootstrap, or for deeper coverage of plane scope choices and immutability rules
- [`./author-a-componenttype.md`](./author-a-componenttype.md), [`./author-a-trait.md`](./author-a-trait.md), [`./author-a-ci-workflow.md`](./author-a-ci-workflow.md), [`./author-a-generic-workflow.md`](./author-a-generic-workflow.md) — for namespace-scoped platform resources after bootstrap
- [`../concepts.md`](../concepts.md) — Namespace / Project / Environment / DeploymentPipeline / DataPlane runtime model
- Upstream doc walkthrough: <https://openchoreo.dev/docs/platform-engineer-guide/namespace-management/>
