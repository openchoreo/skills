# Create an Environment and a Promotion Path

Stand up a new `Environment` (a deployment target — dev, staging, prod, perf, sandbox, region) and wire it into a `DeploymentPipeline` so developers can promote `ComponentRelease`s into it. Fully MCP-driven.

## When to use

- A new env tier — `staging`, `perf`, `sandbox`, `qa`, `pre-production`
- A new region for an existing tier (`production-eu`, `production-us`)
- Splitting a single env into two (e.g. extract `pre-production` from `production`)
- For just a *new namespace* with the standard env trio, see [`./bootstrap-a-namespace.md`](./bootstrap-a-namespace.md) — it sequences environment + pipeline + project together.

## Prerequisites

1. The control-plane MCP server is configured (`list_namespaces` returns).
2. **A `DataPlane` (or `ClusterDataPlane`) must already be registered.** New environments point at an existing plane via `data_plane_ref`. Discover with `list_dataplanes` / `list_cluster_dataplanes` (and `get_*` for status). If the plane you need doesn't exist, that's an install-side concern (handed off to `openchoreo-install`).
3. You know whether this env is production (`is_production: true` gates production-only validations on ComponentTypes / Traits — e.g. "production requires ≥ 2 replicas").
4. To see the canonical layout, inspect what's already on the cluster: `list_environments` and `list_deployment_pipelines` against `default`. The standard dev / staging / prod trio + linear promotion path is the typical starting shape to mimic.

## Recipe

### 1. Pick the data plane

```yaml
list_cluster_dataplanes      # cluster-scoped (the common case)
list_dataplanes              # namespace-scoped (only if a tenant has its own plane)
get_cluster_dataplane
  cdp_name: default          # check status — must be Ready
```

Note the **kind** (`DataPlane` vs `ClusterDataPlane`) — you'll pass it as `data_plane_ref_kind` to `create_environment`. Default is `DataPlane`. Note also the plane's name (the `data_plane_ref` is just the name string; kind is separate).

### 2. Create the environment

```yaml
create_environment
  namespace_name: default
  name: staging
  data_plane_ref: default
  data_plane_ref_kind: ClusterDataPlane
  is_production: false
  display_name: Staging                # optional
  description: Pre-production validation env
```

Note `data_plane_ref` is just the plane *name*; pair with `data_plane_ref_kind` to disambiguate cluster vs namespace scope.

### 3. Decide: extend an existing pipeline, or create a new one

```yaml
list_deployment_pipelines
  namespace_name: default
get_deployment_pipeline
  namespace_name: default
  pipeline_name: default
```

If a pipeline already exists for this namespace and the new env should sit alongside (e.g. `dev → staging → production` plus a new `dev → sandbox` side path), update the existing pipeline. If this is a fresh namespace with no pipeline yet, create one.

### 4a. Update an existing pipeline (add a promotion path)

`update_deployment_pipeline` **replaces `promotion_paths` wholesale** — get the current paths first, append, send back complete:

```yaml
# Current state from get_deployment_pipeline above
# promotion_paths:
#   - source_environment_ref: development
#     target_environment_refs: [{name: staging}]
#   - source_environment_ref: staging
#     target_environment_refs: [{name: production}]

# Add a side path: development → sandbox (alongside development → staging)
update_deployment_pipeline
  namespace_name: default
  pipeline_name: default
  promotion_paths:
    - source_environment_ref: development
      target_environment_refs:
        - name: staging
        - name: sandbox             # new
    - source_environment_ref: staging
      target_environment_refs:
        - name: production
```

Or insert a new env in the middle of a linear chain (`development → qa → staging → production`):

```yaml
update_deployment_pipeline
  namespace_name: default
  pipeline_name: default
  promotion_paths:
    - source_environment_ref: development
      target_environment_refs: [{name: qa}]            # was: staging
    - source_environment_ref: qa
      target_environment_refs: [{name: staging}]       # new
    - source_environment_ref: staging
      target_environment_refs: [{name: production}]
```

### 4b. Create a new pipeline

```yaml
create_deployment_pipeline
  namespace_name: default
  name: tenant-pipeline
  promotion_paths:
    - source_environment_ref: dev
      target_environment_refs: [{name: staging}]
    - source_environment_ref: staging
      target_environment_refs: [{name: production}]
```

The MCP tool sets `kind: Environment` on the source ref automatically; `target_environment_refs[]` entries are objects (kind defaults to `Environment` server-side).

### 5. Verify

```yaml
list_environments
  namespace_name: default
get_environment
  namespace_name: default
  env_name: staging                     # check status.conditions for plane-readiness errors
get_deployment_pipeline
  namespace_name: default
  pipeline_name: default                # confirm promotion_paths reflects the wiring
```

Then have a developer promote a release into it (see `openchoreo-developer/references/recipes/deploy-and-promote.md`).

## Variants

### Namespace-scoped `DataPlane`

If a tenant has their own data plane registered as a namespace-scoped `DataPlane` (rare; mostly for hard isolation tenants):

```yaml
create_environment
  namespace_name: acme
  name: production
  data_plane_ref: acme-prod
  data_plane_ref_kind: DataPlane
  is_production: true
```

Note `DataPlane` is namespace-scoped — the plane must live in the same namespace as the environment.

### Multi-region production (parallel targets)

A single source can promote to multiple targets in one path:

```text
promotion_paths:
  - source_environment_ref: staging
    target_environment_refs:
      - name: production-us-east
      - name: production-eu-west
      - name: production-ap-south
```

A promotion from staging fans out to all listed targets (a developer may still pick a subset on the `ReleaseBinding`-promotion call).

### Sandbox / scratch envs (terminal nodes)

A sandbox env is a target with no outgoing path — promoting from it is intentionally not possible. Just don't list it as `source_environment_ref` anywhere.

## Gotchas

- **`data_plane_ref` is *immutable* on `update_environment`.** Re-pointing an environment to a different plane requires `delete_environment` + `create_environment`, **and re-binding any existing `ReleaseBinding`s** whose `environment` matches. Confirm with the user before deleting; it's destructive.
- **`update_deployment_pipeline` replaces `promotion_paths` wholesale.** Always `get_deployment_pipeline` first; modify the full list locally; send it complete. Omitting an existing path *removes* it.
- **Promotion paths form a directed graph, not a tree.** Adding a side path (`development → sandbox` alongside `development → staging`) doesn't break existing promotions. Removing a path you depended on *will* break in-flight promotions that targeted it.
- **`is_production: true` gates production-only ComponentType validations.** Many built-in `validations[]` rules check `metadata.environmentName == "production"` or similar — but the canonical mechanism is the `is_production` flag. ComponentType authors should consume it via `metadata.environment.isProduction` (where exposed) or by validating against the env name.
- **The plane must be Ready before binding releases.** A new environment can be created against an unready plane, but no `ReleaseBinding` can deploy to it. Verify `get_*_dataplane.status.conditions` shows `Ready: True` and `is_production` matches what you intend.
- **Default to the `default` namespace** unless the user explicitly asks for another (per the SKILL.md guardrail). Multi-tenant onboarding goes through [`./bootstrap-a-namespace.md`](./bootstrap-a-namespace.md), not this recipe.
- **Promotion paths are specified by *environment name*, not UID.** Renaming an environment (which means delete + recreate) breaks every pipeline that references the old name. Update the pipeline at the same time.
- **`update_environment` is partial** (unlike ComponentType / Trait / Workflow which are full-spec replacement). You can change `is_production`, `display_name`, `description` without sending the whole spec — but `data_plane_ref` is rejected as immutable.

## Related

- [`../concepts.md`](../concepts.md) — Environment / DeploymentPipeline / DataPlane runtime model, Cell architecture, plane reads
- [`./bootstrap-a-namespace.md`](./bootstrap-a-namespace.md) — for full namespace bootstrap (namespace + envs + pipeline + project together)
- `openchoreo-developer/references/recipes/deploy-and-promote.md` — the developer-side flow that consumes these
