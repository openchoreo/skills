# Inspect and debug

Read runtime logs, check status conditions, fetch pod-level events, and diagnose common deploy failures.

Read-only. For mutating recovery (rollback, redeploy), see `recipes/deploy-and-promote.md`.

## Status hierarchy

```text
Component (control plane)
  └─ ComponentRelease (control plane)
       └─ ReleaseBinding (control plane → data plane)
            └─ Deployment / Pod / Service / HTTPRoute (data plane)
```

Inspect top-down. The most specific signal — a pod's events or container logs — usually says what's wrong; higher levels just tell you which environment to look in.

## 1. Status conditions

```yaml
get_component
  namespace_name: default
  component_name: my-service
```

Component conditions: `Ready` (overall reconciled), `Finalizing` (deletion in progress).

```yaml
list_release_bindings
  namespace_name: default
  component_name: my-service

get_release_binding
  namespace_name: default
  binding_name: my-service-development
```

ReleaseBinding conditions:

| Condition | Healthy value | Means |
|---|---|---|
| `ReleaseSynced` | `True` | RenderedRelease created / updated |
| `ResourcesReady` | `True` | All resources in the data plane are healthy |
| `Ready` | `True` | Overall — both above are `True` |
| `ConnectionsResolved` | `True` | Dependency env vars injected |

`status.endpoints[]` holds the deployed URLs.

## 2. Discover rendered resource names

`get_resource_events` and `get_resource_logs` need exact rendered K8s names — usually different from the component name. `get_resource_tree` is the bridge:

```yaml
get_resource_tree
  namespace_name: default
  release_binding_name: my-service-development
```

Returns one entry per `RenderedRelease` (data plane, plus observability plane if traits attach there). Each entry's nodes list `group`, `version`, `kind`, `name`, parent refs, and health. Pluck the `kind` + `name` for the next call.

## 3. Logs and events

**Container logs** — `get_resource_logs` reads stdout/stderr for a specific pod under a binding:

```yaml
get_resource_logs
  namespace_name: default
  release_binding_name: my-service-development
  pod_name: my-service-7f9c-abc12         # from get_resource_tree (kind: Pod)
  since_seconds: 300                       # optional, last 5 minutes
```

**K8s events** — `get_resource_events` covers scheduling, image pulls, OOMs, container starts — anything the pod's stdout can't show:

```yaml
get_resource_events
  namespace_name: default
  release_binding_name: my-service-development
  group: apps                              # core resources use ""
  version: v1
  kind: Deployment                          # or Pod, Service, …
  resource_name: <rendered name from get_resource_tree>
```

All four of `group`, `version`, `kind`, `resource_name` are required.

## 4. Investigate a crashloop

1. `get_component` → conditions. If `Ready: False`, the message says why.
2. `get_release_binding` → `ReleaseSynced` / `ResourcesReady` / `Ready`.
3. `get_resource_tree` to get rendered Deployment / Pod names.
4. `get_resource_events` (kind: Deployment) for image pull / quota / scheduling errors.
5. `get_resource_events` (kind: Pod) for `BackOff`, `Killed`, `OOMKilled`.
6. `get_resource_logs` for the container stderr.

App-side cause → developer fix. Plane-side cause → escalate to PE.

## Common failure matrix

| Symptom | First check |
|---|---|
| `CrashLoopBackOff` | `get_resource_events` (Pod), then `get_resource_logs` |
| `ImagePullBackOff` | `get_resource_events` (Pod) — exact error in message |
| `OOMKilled` | `get_resource_events`, then bump `resources.limits.memory` per `recipes/override-per-environment.md` |
| Pod `Pending` long time | `get_resource_events` (Pod); cluster-pressure → PE |
| Endpoint URL not reachable | `get_release_binding.status.endpoints[]`; missing → gateway / PE |
| No binding for a component | `list_release_bindings`; if empty → `recipes/deploy-and-promote.md` |

## Gotchas

- **Use canonical condition names.** ReleaseBinding has `ReleaseSynced`, `ResourcesReady`, `Ready` — not `Deployed` / `Synced`.
- **`list_release_bindings` requires `namespace_name` and `component_name`.** Project is not a parameter; the binding is looked up by component.
- **`get_resource_logs` returns nothing when the container can't start.** `ImagePullBackOff` and similar leave nothing in stdout — use `get_resource_events` (Pod kind) instead.
- **`Ready: True` briefly during rollout.** A pod can flap Ready before crashing again. Confirm with logs.
- **Rendered resource names ≠ component name.** `get_resource_events` matches `(group, version, kind, name)` exactly — passing the component name fails. Always `get_resource_tree` first.
- **`get_resource_logs` is current-container only.** Previous-container logs (after a restart) aren't retrievable — escalate to PE for `kubectl logs --previous`.
- **Promotion preserves the failure.** A broken release in dev stays broken in staging. Roll back first.

## Out of scope

Aggregated metrics, traces, alerts, incidents, and historical log search across replicas — hand off to platform engineering.

## Related

- [`deploy-prebuilt-image.md`](deploy-prebuilt-image.md) / [`build-from-source.md`](build-from-source.md) — what produced the running release
- [`deploy-and-promote.md`](deploy-and-promote.md) — rollback, redeploy
- [`configure-workload.md`](configure-workload.md) / [`override-per-environment.md`](override-per-environment.md) — fix the underlying config
