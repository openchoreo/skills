# Inspect and debug

Read runtime logs, check status conditions, fetch pod-level events, and diagnose common deploy failures (CrashLoopBackOff, ImagePullBackOff, NotReady).

## When to use

- "Is my deploy working?" — verify after `recipes/deploy-prebuilt-image.md`, `recipes/build-from-source.md`, or `recipes/deploy-and-promote.md`
- "Why isn't it working?" — service is `NotReady`, pods are crashing, endpoints aren't reachable
- Routine log-reading during development
- Triage before deciding whether to escalate to PE

This recipe is read-only. For mutating recovery (rollback, redeploy), see `recipes/deploy-and-promote.md`.

## Status hierarchy

```
Component (control plane)
  └─ ComponentRelease (control plane)
       └─ ReleaseBinding (control plane → data plane)
            └─ Deployment / Pod / Service / HTTPRoute (data plane)
```

Inspect top-down. The most specific signal — a pod's events or container logs — usually says what's wrong; higher levels just tell you which environment to look in.

## Recipe — check status

### Component-level (resource conditions)

```
get_component
  namespace_name: default
  component_name: my-service
```

Look at `status.conditions[]`:

| Condition type | Healthy value | Means |
|---|---|---|
| `Ready` | `True` | Component overall is reconciled |
| `Reconciled` | `True` | Controller picked up the latest spec |

```
get_workload
  namespace_name: default
  workload_name: my-service-workload
```

### ReleaseBinding-level (per-environment health)

```
list_release_bindings
  namespace_name: default
  component_name: my-service

get_release_binding
  namespace_name: default
  binding_name: my-service-development
```

| Condition type | Healthy value | Means |
|---|---|---|
| `Ready` | `True` | Binding is up |
| `Deployed` | `True` | Resources reached the data plane |
| `Synced` | `True` | Data plane matches the spec |

`status.endpoints[]` holds the deployed URLs.

## Recipe — runtime logs (pod-level)

Runtime logs come from the control-plane `get_resource_logs` tool — direct container stdout/stderr for a specific pod under a binding. Find pod names via `get_resource_events` (or the binding status) first.

```
get_resource_events
  namespace_name: default
  release_binding_name: my-service-development
  group: ""
  version: v1
  kind: Pod
  resource_name: my-service          # the workload's pod prefix; events surface concrete pod names

get_resource_logs
  namespace_name: default
  release_binding_name: my-service-development
  pod_name: my-service-7f9c-abc12
  since_seconds: 300                 # last 5 minutes; optional
```

For longer-horizon log history, structured search, log-level filters, or metric/trace/alert data, fall back to `kubectl logs` (PE-only) or escalate to `openchoreo-platform-engineer`.

## Recipe — Deployment-level events

When the container can't start (e.g. `ImagePullBackOff`) or you need K8s events for scheduling / OOM / quota issues, query the Deployment kind:

```
get_resource_events
  namespace_name: default
  release_binding_name: my-service-development
  group: apps
  version: v1
  kind: Deployment
  resource_name: my-service          # the Deployment name in the data plane
```

Use this for `ImagePullBackOff`, scheduling failures, OOM kills, etc. — events the pod logs can't show.

## Recipe — investigate a crashloop

A reusable flow when "the deploy says Ready but the app isn't responding" or "Component is NotReady":

1. **Component conditions** — `get_component`, look at `status.conditions[]`. If `Ready: False`, read the `message` field for the reason.
2. **ReleaseBinding conditions** — `get_release_binding`. If `Deployed: True` but `Synced: False`, the data plane is mid-rollout; wait, then re-check.
3. **Resource events on the Deployment** — `get_resource_events` with `kind: Deployment`. Look for image pull errors, quota issues, scheduling problems.
4. **Resource events on the Pod** — same call with `kind: Pod`, `resource_name: <pod name>`. Look for `BackOff`, `Killed`, `OOMKilled`.
5. **Pod logs** — `get_resource_logs` to read the crashing container's stderr (find the pod name via the Pod-kind events from step 4).

If the cause is in the application (bad config, missing env var, dependency unreachable), it's a developer fix. If the cause is plane-level (data plane disconnected, controller stuck, gateway misconfigured), escalate to `openchoreo-platform-engineer`.

## Common failure matrix

| Symptom | Likely cause | First check |
|---|---|---|
| Component stuck `NotReady` | Data plane connectivity | `get_release_binding` status, then escalate to PE if data-plane side |
| Pod `CrashLoopBackOff` | Application error / bad config | `get_resource_events` (Pod kind) for restart reason, then `get_resource_logs` for the container stderr |
| `ImagePullBackOff` | Wrong image URL or missing credentials | `get_resource_events` on the Pod for the exact error; for private registry, see `recipes/deploy-prebuilt-image.md` |
| Endpoint URL not reachable | HTTPRoute not created or gateway misconfigured | `get_release_binding` `status.endpoints[]` first; if missing, escalate to PE |
| Deployment doesn't appear | ReleaseBinding never created | `list_release_bindings` — if empty, see `recipes/deploy-and-promote.md` |
| Pod `OOMKilled` | Memory limit too low | `get_resource_events` for the kill, then `recipes/override-per-environment.md` to bump `resources.limits.memory` |
| Pod `Pending` long time | Cluster resource pressure or scheduling | `get_resource_events` on the Pod; PE concern if cluster-wide |

## Metrics, traces, alerts, incidents

For P99 latency spikes, request error rates, distributed traces, fired alerts, or open incidents, hand off to platform engineering — they can `kubectl logs` the observability plane or query the observability backend directly.

## Gotchas

- **`status.conditions` is the source of truth.** Don't infer from indirect signals (e.g. logs not appearing) — read the conditions first. `get_component` and `get_workload` both surface `status.conditions[]` — each condition has `type`, `status`, `reason`, `message`. Always check conditions when debugging.
- **`list_release_bindings` requires both project and component.** Pass both, not just project — calling it with project alone returns nothing useful.
- **`get_resource_logs` returns nothing when the container can't start.** `ImagePullBackOff` and similar leave nothing in the pod's stdout. Switch to `get_resource_events` (Pod kind) for those.
- **`Ready: True` briefly during rollout.** A pod can flap to `Ready` for a few seconds before crashing again. Always confirm with logs that the app actually started.
- **`get_resource_logs` needs a known `pod_name`.** There's no `list_pods` MCP. Get the name from the binding's status, or from `get_resource_events` (events list pod names in `involvedObject`).
- **`get_resource_logs` is current-container only.** Previous-container logs (after a restart) aren't retrievable via this tool — escalate to PE for `kubectl logs --previous`.
- **Per-environment logs filter via the binding name.** Each binding is one (component, environment) pair. A single component running in dev + staging has two bindings, each with its own pods.
- **Promotion preserves the failure mode.** If a release is broken in dev, promoting it deploys the same broken release to staging. Rollback first (`recipes/deploy-and-promote.md`) before re-promoting.

## Related recipes

- [`deploy-prebuilt-image.md`](deploy-prebuilt-image.md) / [`build-from-source.md`](build-from-source.md) — what produced the running release
- [`deploy-and-promote.md`](deploy-and-promote.md) — rollback once you've identified a bad release
- [`configure-workload.md`](configure-workload.md) / [`override-per-environment.md`](override-per-environment.md) — fix the underlying config
