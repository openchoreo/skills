# Connect components (endpoint dependencies)

Wire one Component to another's endpoint so OpenChoreo injects the resolved service address as an env var. Uses `spec.dependencies.endpoints[]` on the consuming Workload.

## When to use

- One component needs to call another component's endpoint
- The user is hardcoding hostnames or guessing service DNS — replace with a dependency
- Cross-project dependencies (e.g. an app calling a shared `auth-service` in a `platform-services` project)
- For attaching plain env vars or secrets unrelated to other components, use `recipes/configure-workload.md` / `recipes/manage-secrets.md`

## Prerequisites

> **The dependency entry's `visibility` is constrained to `project` or `namespace` only.** The API rejects `internal` and `external` on `dependencies.endpoints[*].visibility` — those two levels exist for *target endpoint declarations* (ingress) and for non-dependency consumers, not for service-to-service dependency wiring. **Cross-namespace dependencies are not supported** via this mechanism; if you need one, escalate to `openchoreo-platform-engineer` (a gateway / network-policy approach).
>
> **Default `visibility: project`.** Same-project, same-environment is the baseline — that's what a Project's Cell is for, and it does not require any gateway routing. Pick `namespace` only when the consumer and target are actually in different projects of the same namespace. Confirm both components' projects via `get_component` before deciding.

1. Both Components exist and the **target's endpoint visibility is broad enough** for the consumer. Pick the dependency entry's `visibility` field from this table:

| Consumer / target relationship | Set `visibility:` to | Target endpoint must declare at least |
|---|---|---|
| same project + same environment | `project` (default) | `project` (implicit on every endpoint) |
| different project, same namespace | `namespace` | `namespace` |
| different namespace | *not supported* | — |

1. Visibility on the target endpoint is a *list*, so a target can have e.g. `[namespace, external]` and serve both same-project and cross-project consumers. The four target-side visibility levels are `project`, `namespace`, `internal`, `external`. The two dependency-side options are a strict subset (`project`, `namespace`).

2. **The dependency entry uses `name:` (the target endpoint name on the dependency component), not `endpoint:`.** The pre-v1.0.0 `endpoint:` field is gone. Discover the target's endpoint names via `get_workload` first.

To inspect a target's endpoint visibility:

```yaml
get_workload
  namespace_name: default
  workload_name: <target>-workload
```

## Recipe

### 1. Read the consuming Workload

```yaml
get_workload
  namespace_name: default
  workload_name: frontend-workload
```

### 2. Add `dependencies.endpoints[]` and update

Send the full updated `workload_spec` with a new `dependencies` block:

```yaml
update_workload
  namespace_name: default
  workload_name: frontend-workload
  workload_spec:
    owner: {projectName: default, componentName: frontend}
    container: {...}                  # unchanged from the read
    endpoints: {...}                  # unchanged from the read
    dependencies:
      endpoints:
        - component: user-service     # target component name
          name: http                  # target endpoint name (NOT "endpoint")
          visibility: project
          envBindings:
            address: USER_SERVICE_URL
```

OpenChoreo injects `USER_SERVICE_URL` (and any other env vars in `envBindings`) into the consumer's container at runtime. The dependency makes a new ComponentRelease.

### 3. Verify after redeploy

Once the redeploy is `Ready`, **don't trust Ready by itself** — a perfectly stable pod can be Ready and entirely broken if the env var name your app reads doesn't match what's bound (silent `nil` connects, no crash, no restart). Verify functionally:

1. **Exercise the actual endpoint** — curl an `external` URL from `get_release_binding` → `status.endpoints[*].externalURLs`, or for internal-only services hit it from a sibling pod / port-forward. A 200 with the expected body is the only proof the wiring works.
2. **Then** confirm the env var resolved by reading container logs:

```yaml
get_resource_events
  namespace_name: default
  release_binding_name: frontend-development
  group: ""
  version: v1
  kind: Pod
  resource_name: frontend            # the workload's pod prefix; events surface concrete pod names

get_resource_logs
  namespace_name: default
  release_binding_name: frontend-development
  pod_name: <pod from events above>
```

Look for `USER_SERVICE_URL` in startup logs or grep against the printed env. For deeper inspection, see `recipes/inspect-and-debug.md`.

## Patterns

### Same-project dependency

```yaml
dependencies:
  endpoints:
    - component: user-service
      name: http
      visibility: project              # implicit default; same project, same env
      envBindings:
        address: USER_SERVICE_URL
```

### Cross-project dependency

```yaml
dependencies:
  endpoints:
    - component: shared-auth-service
      name: http
      visibility: namespace            # broader than project
      project: platform-services       # required when target is in a different project
      envBindings:
        address: AUTH_SERVICE_URL
        host: AUTH_SERVICE_HOST
        port: AUTH_SERVICE_PORT
```

The target's `endpoints.http.visibility` must include `namespace` (or broader).

### Multiple dependencies

```yaml
dependencies:
  endpoints:
    - component: user-service
      name: http
      visibility: project
      envBindings:
        address: USER_SERVICE_URL
    - component: notification-service
      name: grpc
      visibility: project
      envBindings:
        address: NOTIFICATION_SERVICE_ADDR
    - component: analytics-api
      name: http
      visibility: namespace
      project: analytics
      envBindings:
        address: ANALYTICS_API_URL
        basePath: ANALYTICS_API_BASE_PATH
```

### SPA frontend with HTTP + Websocket backends (same project)

A common multi-backend pattern: a browser-side SPA in the same project as a REST backend and a Websocket backend. The frontend declares both as same-project dependencies; the platform handles Websocket protocol upgrade natively when the target endpoint `type` is `Websocket`. **Don't** add a custom reverse-proxy or protocol-upgrade configuration (nginx, Caddy, Envoy sidecar, etc.) — set the target's endpoint type and let OpenChoreo route it.

Target backends' workload spec (excerpt):

```yaml
endpoints:
  api:
    type: HTTP
    port: 8080
    visibility: [project, external]   # external so the browser can reach it
  ws:
    type: Websocket
    port: 8081
    visibility: [project, external]
```

Frontend's workload spec (excerpt):

```yaml
dependencies:
  endpoints:
    - component: document-svc
      name: api
      visibility: project              # default — same-project link
      envBindings:
        address: DOCUMENT_API_URL
    - component: collab-svc
      name: ws
      visibility: project
      envBindings:
        address: COLLAB_WS_URL
```

For a browser-side SPA, the runtime URLs the browser actually fetches must be the **external** addresses from `get_release_binding` → `endpoints[*].externalURLs`, served via a mounted `config.json` (use `https://` and `wss://` schemes). The `dependencies.endpoints[]` declaration is still required — it makes the connection visible in the cell topology and tells the platform which components talk to which. See `recipes/configure-workload.md` for the file-mount pattern. Reference samples: `samples/from-image/echo-websocket-service/` and the platform docs for protocol-upgrade behaviour.

## envBindings keys

Each binding takes one or more of:

| Key | Injects | Example value |
|---|---|---|
| `address` | full address | `http://user-service.default.svc.cluster.local:9090/api` |
| `host` | hostname only | `user-service.default.svc.cluster.local` |
| `port` | port number only | `9090` |
| `basePath` | base path only (HTTP only) | `/api` |

The format of `address` depends on the endpoint type:

- `HTTP` / `GraphQL`: `http://host:port/basePath`
- `Websocket`: `ws://host:port/basePath` (in-cluster scheme; for browser-facing access, use the external `wss://` URL from `get_release_binding` → `endpoints[*].externalURLs`, not this injected value)
- `gRPC` / `TCP` / `UDP`: `host:port` (no scheme, no path)

If the target endpoint has no `basePath`, `address` ends at `host:port` with no trailing slash.

The right side of each `envBindings` entry is the env var name in the consumer.

> **When the consumer needs a value `envBindings` can't give you directly** (a connection-string DSN, a compound URL, anything stitched from multiple pieces or in a non-standard scheme), two options:
>
> - **Per-env override on the consumer's ReleaseBinding** — deploy the dep first, read its live endpoint via `get_release_binding` → `status.endpoints[*].serviceURL.host` and `.port`, compose the value the consumer needs, set it as a literal in `workloadOverrides.env`. Each env binding carries its own value; same `ComponentRelease` promotes cleanly. See [`./override-per-environment.md`](./override-per-environment.md).
> - **Stitch in app code** — inject `host`, `port` etc. as separate env vars via `envBindings`; the app builds the DSN at startup. No platform-side override needed; requires a small code change.
>
> Embedded credentials should still come from a `SecretReference` via `valueFrom.secretKeyRef` in either of the above.

## Gotchas

- **Always wire connections through `dependencies.endpoints[]` with an `envBindings` entry — even when the value the app actually reads is supplied elsewhere.** The dependency declaration is what makes the link visible in the cell topology UI and tells the platform which components talk to which; an env var the app sets via `workloadOverrides.env` (or anywhere outside the dependency) does *not* show up as a connection. If the natural envBindings injection doesn't match what the app reads — wrong env var name, wrong value shape, or you need a stitched DSN handled in `workloadOverrides.env` — bind to a **dummy env var name the app does not read** (e.g. `_DEP_USER_SERVICE_URL`). The dummy keeps the dependency visible without colliding with the real env var the app actually consumes. *Why this matters:* if the app's expected env var is `REDIS_SERVER_ENDPOINT` but you skip envBindings entirely and only set it via overrides, the topology view shows no link, and the next person debugging connectivity has no signal that the wiring is intentional.
- **Dependencies live at `spec.dependencies.endpoints[]`, not flat `spec.dependencies[]` or `spec.connections[]`.** The pre-v1.0.0 flat shape is gone. Each entry uses `name` for the target endpoint name — not `endpoint`.
- **`update_workload` sends the full spec** — read first, append the dependency, send back. See `recipes/configure-workload.md` for the same gotcha.
- **Visibility mismatch is silent until reconcile.** `update_workload` accepts a dependency whose target visibility is too narrow, but the ReleaseBinding fails to bind. Check `status.conditions` on the ReleaseBinding for the actual error.
- **Cross-project dependencies require both `visibility: namespace` and `project: <target-project>`.** Missing `project` defaults to the same project — the binding fails with "endpoint not found" because the controller looks in the wrong project.
- **Dependency entry's `visibility` is `project` or `namespace` only.** The API rejects `internal` and `external` here. Cross-namespace dependencies are not supported via this mechanism — escalate to PE for a gateway-based approach.
- **Consumer's visibility request must be ≤ what the target declares.** Asking for `namespace` against a target whose endpoint visibility is `[project]` fails reconciliation. Either lower the consumer's visibility (only `project` works for a project-only target) or have the target add `namespace` to its endpoint visibility list.
- **Max 50 endpoint dependencies per Workload.** A consumer pulling from more than 50 components is a design smell — split it.
- **Connection refused after deploy?** Confirm the target's endpoint visibility list includes the level the consumer is asking for. Most "it deployed but can't connect" issues trace to this.
- **The injected `address` already includes the scheme (HTTP/WS).** Don't prepend `http://` in the consumer's code when using `address`. If you need just the host, use `envBindings.host` instead.
- **Don't stitch values via `$(VAR)` substitution against dependency-injected env vars.** Doesn't reliably work; the placeholder ends up verbatim in the running container.

## Related recipes

- [`configure-workload.md`](configure-workload.md) — endpoint visibility, env vars, files
- [`manage-secrets.md`](manage-secrets.md) — secret-referenced env vars (for credentials, not service addresses)
- [`inspect-and-debug.md`](inspect-and-debug.md) — verify the env var injected and the connection succeeded
- [`deploy-and-promote.md`](deploy-and-promote.md) — promotion across environments preserves dependency wiring
