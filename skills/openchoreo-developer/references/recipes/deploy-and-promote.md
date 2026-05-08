# Deploy and promote

Deploy a Component release to its first environment and promote it through the pipeline (e.g. `development → staging → production`). Also: rollback to an older release, undeploy, and redeploy an undeployed binding.

## When to use

- A new Component release is ready and needs to reach the first environment
- A working release needs to move from one environment to the next
- A bad release needs to roll back to an earlier known-good one
- A binding needs to be temporarily removed (`Undeploy`) without losing its config
- An undeployed binding needs to be re-activated

## How releases and bindings relate

```text
Component + Workload
        ↓
ComponentRelease (immutable snapshot, named like {component}-<hash>)
        ↓
ReleaseBinding (one per environment — what's actually deployed there)
        ↓
Deployment + Service + HTTPRoute (in the data plane)
```

`auto_deploy: true` on the Component creates the **first environment's** ReleaseBinding automatically when a new ComponentRelease appears. Subsequent environments are manual.

To list releases for a component:

```yaml
list_component_releases
  namespace_name: default
  component_name: my-service
```

To list current bindings:

```yaml
list_release_bindings
  namespace_name: default
  component_name: my-service
```

## Recipe — first environment

If `auto_deploy: true` was set on `create_component`, the first environment's ReleaseBinding is created automatically when the ComponentRelease lands. Skip ahead to verification.

If `auto_deploy: false` (or you want explicit control), create the binding manually:

```yaml
create_release_binding
  namespace_name: default
  project_name: default
  component_name: my-service
  environment: development
  release_name: my-service-5d7f658d9c
```

### Verify

```yaml
get_release_binding
  namespace_name: default
  binding_name: my-service-development
```

`status.conditions[]` should show `Ready: True`, `Deployed: True`, `Synced: True`. Read the deployed URL from `status.endpoints[]`.

## Recipe — promote to next environment

Promotion is "create a new ReleaseBinding for the next environment, pointing at the same release." Pipelines define the allowed source → target paths; the platform validates against them.

```yaml
create_release_binding
  namespace_name: default
  project_name: default
  component_name: my-service
  environment: staging
  release_name: my-service-5d7f658d9c     # same release that's running in dev
```

For per-environment overrides at promotion time, see `recipes/override-per-environment.md` — pass `component_type_environment_configs`, `trait_environment_configs`, and `workload_overrides` on the same call.

### Verify

```yaml
list_release_bindings
  namespace_name: default
  component_name: my-service
```

Confirm a binding now exists for `staging` with the expected `release_name`. Then check status as above.

## Variant — rollback to a previous release

Rollback = point an existing ReleaseBinding at an older ComponentRelease. The release stays in the registry forever (releases are immutable); only the binding's `release_name` changes.

### Find the older release

```yaml
list_component_releases
  namespace_name: default
  component_name: my-service
```

The output lists all releases for the component. Pick the older release name to roll back to.

### Update the binding

```yaml
update_release_binding
  namespace_name: default
  binding_name: my-service-production
  release_name: my-service-a1b2c3d4e5     # the older release to roll back to
```

### Verify

`status.conditions[]` flips through `Synced: False` while the new release rolls out, then back to `Synced: True`. Watch logs to confirm the older code is running. Find the new pod name via `get_resource_events`, then read its container logs:

```yaml
get_resource_events
  namespace_name: default
  release_binding_name: my-service-production
  group: ""
  version: v1
  kind: Pod
  resource_name: my-service

get_resource_logs
  namespace_name: default
  release_binding_name: my-service-production
  pod_name: <pod from events above>
```

## Variant — undeploy

Take a binding offline without deleting it. Config (overrides, release pointer) stays intact for a future redeploy.

```yaml
update_release_binding
  namespace_name: default
  binding_name: my-service-staging
  release_state: Undeploy
```

Valid `release_state` values: `Active`, `Undeploy`. `update_release_binding` is a partial update — only the field(s) you pass change, so this leaves overrides and `release_name` untouched.

The Deployment, Service, and HTTPRoute in the data plane disappear; the ReleaseBinding resource itself stays. Re-activating restores them with the same config.

## Variant — redeploy an undeployed binding

```yaml
update_release_binding
  namespace_name: default
  binding_name: my-service-staging
  release_state: Active
```

The Deployment / Service / HTTPRoute come back with the binding's existing release and overrides. To redeploy with a *different* release at the same time, pass both fields in one call: `update_release_binding release_state: Active, release_name: <new>`.

## Variant — hard-delete a binding

When the binding is no longer needed (not just temporarily down), `delete_release_binding namespace_name: <ns>, binding_name: <name>` removes the ReleaseBinding resource itself. Config and overrides are gone — destructive, no automatic redeploy path. Confirm with the user before running. For reversible removal, prefer `release_state: Undeploy` above.

## Gotchas

- **`auto_deploy` only auto-creates the *first* environment's binding.** Promotion to staging/prod is always manual or via GitOps.
- **Releases are immutable.** Once a ComponentRelease exists, its image and Workload spec are frozen. You cannot "edit" a release — make a new ComponentRelease (by updating the Workload) and point the binding at it.
- **`create_release_binding` fails if a binding already exists for that environment.** To change the release in an existing binding, use `update_release_binding release_name: <new>`. The MCP tool description says this explicitly.
- **Pipelines gate promotion paths.** If the pipeline only allows `dev → staging → prod`, you cannot skip from `dev → prod` directly. Override at the PE side or change the pipeline.
- **Promoted bindings start without overrides.** Each environment's ReleaseBinding is independent — promotion creates a fresh binding for the new env. Re-apply per-environment overrides explicitly. See `recipes/override-per-environment.md`.
- **`Undeploy` does not delete the binding.** It just removes the data-plane resources. The ReleaseBinding resource itself stays with all config intact, ready for a future redeploy.
- **Rollback only changes `release_name`** — env-specific overrides on the binding survive. If the older release expected different env vars, you may need to also update `workload_overrides` on the same call.
- **`create_release_binding` requires all five of `namespace_name`, `project_name`, `component_name`, `environment`, `release_name`.** `release_name` is not optional. If `auto_deploy: true` and the Workload just changed, a fresh ComponentRelease is created automatically — find its name via `list_component_releases`.

## Related recipes

- [`override-per-environment.md`](override-per-environment.md) — overrides applied at promotion time
- [`inspect-and-debug.md`](inspect-and-debug.md) — verify the new release deployed cleanly
- [`configure-workload.md`](configure-workload.md) — changing the base Workload generates a new release
- [`deploy-prebuilt-image.md`](deploy-prebuilt-image.md) / [`build-from-source.md`](build-from-source.md) — produce the releases you'll promote
