# Configure a Workload

Add or change endpoints, environment variables, config files, and traits on a Component / Workload after the initial deploy. Most fields live on the Workload (`spec.container`, `spec.endpoints`); traits attach to the Component (`spec.traits[]`).

## Prerequisites

A Component and Workload already exist. If not, see `recipes/deploy-prebuilt-image.md` or `recipes/build-from-source.md` first.

## Recipe

### 1. Read the current Workload

```yaml
get_workload
  namespace_name: default
  workload_name: greeter-workload
```

If unsure of the spec shape:

```text
get_workload_schema
  (no parameters)
```

### 2. Update the Workload

Edit the spec locally, then send the full updated `workload_spec`:

```yaml
update_workload
  namespace_name: default
  workload_name: greeter-workload
  workload_spec:
    owner:
      projectName: default
      componentName: greeter
    container:
      image: ghcr.io/openchoreo/samples/greeter-service:v2
      env:
        - key: LOG_LEVEL
          value: debug
        - key: DB_PASSWORD
          valueFrom:
            secretKeyRef:
              name: db-secret
              key: password
      files:
        - key: app.yaml
          mountPath: /etc/config
          value: |
            server:
              port: 8080
    endpoints:
      http:
        type: HTTP
        port: 9090
        visibility: [external]
        basePath: /api/v1
      grpc:
        type: gRPC
        port: 9091
        visibility: [namespace]
```

`update_workload` sends the full `workload_spec`, not a partial patch — read first, modify locally, send back.

A new ComponentRelease is generated automatically; `auto_deploy: true` (set on the Component) triggers redeploy to the first environment.

### 3. Verify

```yaml
get_release_binding
  namespace_name: default
  binding_name: <name from list_release_bindings>
```

Check `status.conditions[]` for `Ready`, `ReleaseSynced`, `ResourcesReady` all `True`. For runtime logs, see `recipes/inspect-and-debug.md`.

## Configuration patterns

### Endpoints

```yaml
endpoints:
  http:
    type: HTTP                       # HTTP | gRPC | GraphQL | Websocket | TCP | UDP
    port: 8080                       # container listening port
    targetPort: 8080                 # optional, defaults to port
    visibility: [external]           # [project]+[namespace]+[internal]+[external] — list any combination
    basePath: /api/v1                # optional, HTTP-only
    displayName: REST API            # optional
    schema: {}                       # optional OpenAPI spec object
```

Visibility levels (broader → narrower):

| Level | Reachable from |
|---|---|
| `external` | Public internet, via gateway |
| `internal` | Anywhere inside the deployment topology |
| `namespace` | All projects in same namespace + environment |
| `project` | Same project + environment (implicit if no level given) |

Visibility is a list — an endpoint can expose itself at multiple levels at once (e.g. `[namespace, external]`).

> **Non-HTTP endpoints are first-class.** Set `type: Websocket`, `gRPC`, `TCP`, `UDP`, or `GraphQL` directly. The platform's gateway handles Websocket protocol upgrade and gRPC HTTP/2 routing natively — **don't add a custom reverse-proxy or protocol-upgrade configuration** of any kind (nginx upgrade headers, Caddy / Envoy / Traefik route rules, sidecars) for these protocols. Reference samples: `samples/from-image/echo-websocket-service/`, `samples/from-image/grpc-service/` in the OpenChoreo repo. For multi-protocol patterns (e.g. a Websocket endpoint alongside an HTTP endpoint on the same component), define each as its own entry in the `endpoints:` map.

### Environment variables

```yaml
container:
  env:
    - key: LOG_LEVEL
      value: info                                   # literal
    - key: DB_PASSWORD
      valueFrom:
        secretKeyRef:                               # reference a SecretReference
          name: db-secret
          key: password
```

Each entry needs **exactly one** of `value` or `valueFrom`. For SecretReference setup, see `recipes/manage-secrets.md`. For dependency-injected env vars (service URLs of other components), see `recipes/connect-components.md`.

### Configuration files

In a Workload CR (sent via `update_workload`):

```yaml
container:
  files:
    - key: config.yaml
      mountPath: /etc/config
      value: |                                      # literal content
        server:
          port: 8080
    - key: tls.crt
      mountPath: /etc/tls
      valueFrom:
        secretKeyRef:                               # from SecretReference
          name: tls-certs
          key: certificate
```

> **Field naming differs between Workload CR and `workload.yaml` descriptor.** The Workload CR (this recipe's MCP path) uses `container.env[]` / `container.files[]` with `key:`. The `workload.yaml` descriptor in the source repo uses `configurations.env[]` / `configurations.files[]` with `name:` instead of `key:`. The descriptor also supports `valueFrom.path: <repo-relative path>` to inline a file from the repo at build time — that's descriptor-only; the runtime Workload CR has no repo access.

### Resources and replicas

These usually live in the **Component's `parameters`** field, not the Workload:

```yaml
spec:
  parameters:
    replicas: 2
    resources:
      requests: {cpu: 100m, memory: 128Mi}
      limits:   {cpu: 500m, memory: 512Mi}
```

The exact parameter set depends on the ClusterComponentType — discover with `get_cluster_component_type_schema name: deployment/service`.

For per-environment differences (more replicas in prod), override at the ReleaseBinding level — see `recipes/override-per-environment.md`.

### Traits

Traits live on the Component, not the Workload. Attach (or replace the trait list) via `patch_component`:

```yaml
patch_component
  namespace_name: default
  project_name: default
  component_name: greeter
  traits:
    - kind: ClusterTrait                            # required — defaults to namespace-scoped Trait
      name: observability-alert-rule
      instanceName: high-error-rate                 # unique per Component
      parameters:
        severity: critical
        source: {type: log, query: "status:error"}
        condition: {window: 5m, operator: gt, threshold: 50}
```

`traits` on `patch_component` is **whole-list replace at the slice level** — pass every trait you want the Component to keep. An empty array clears all traits; omitting `traits` leaves the existing list unchanged. Discover available traits via `list_cluster_traits`; get a trait's parameter schema via `get_cluster_trait_schema`.

## Gotchas

- **OpenChoreo containers run as non-root — don't bind to ports below 1024.** The data plane runs each pod under a non-root UID with no `CAP_NET_BIND_SERVICE`, so `listen 80` (default nginx config), `EXPOSE 80`, or any explicit bind to a privileged port fails at startup with `bind: permission denied` and the pod ends up in `CrashLoopBackOff`. Common fixes: switch nginx to `listen 8080`, drop `EXPOSE 80` from the Dockerfile, set the Workload `endpoints[*].port` and `targetPort` to the same non-privileged port, and update any health-check probes. The platform's gateway terminates :80 / :443 externally; containers always speak the unprivileged port. If you absolutely need a privileged port inside the container, that's a PE-side capability change, not a Workload tweak.
- **`update_workload` sends the full spec, not a partial patch.** Always `get_workload` first, modify locally, send the complete `workload_spec`. Omitting a field deletes it.
- **`update_workload` only takes `namespace_name`, `workload_name`, `workload_spec`.** It does not accept `project_name` or `component_name`. Use `list_workloads` to find the workload name first.
- **File mount `mountPath` is a directory.** The controller appends the `key` name to `mountPath` to form the final file path. Set `mountPath` to the parent directory (`/usr/share/nginx/html`), not the full file path (`/usr/share/nginx/html/config.json`). Using the full file path doubles the filename: `.../config.json/config.json`.
- **Browser-facing apps need `https://` and `wss://` backend URLs.** OpenChoreo serves web-application components over HTTPS. Any backend URLs injected at runtime (e.g. via a mounted `config.json`) must use `https://` and `wss://` — HTTP/WS URLs are blocked by browsers as mixed content (no visible error, requests silently fail). Get external URLs from `get_release_binding` → `endpoints[*].externalURLs` and use the `https` scheme.
- **`env` and `files` entries need exactly one of `value` or `valueFrom`** — not both, not neither. Validation fails otherwise.
- **Workload CR uses `key:`; `workload.yaml` descriptor uses `name:`** under `configurations.env[]` / `configurations.files[]`. Easy to mix up when copy-pasting between recipes.
- **`valueFrom.path` only works in source-build `workload.yaml`** at build time. For Workload CRs (BYOI or post-build update via MCP), use literal `value` or `valueFrom.secretKeyRef`.
- **`componentType.kind` and `traits[].kind` default wrong.** Both default to namespace-scoped (`ComponentType` / `Trait`). Built-ins are cluster-scoped (`ClusterComponentType` / `ClusterTrait`). Always set `kind` explicitly.
- **Visibility on a dependency must be ≤ visibility on the target endpoint.** A consumer asking for `namespace` visibility against a target that only declares `project` visibility fails. See `recipes/connect-components.md` for the dependency rules.
- **Updating the Workload triggers a new ComponentRelease and (if `auto_deploy: true`) redeploys to the first environment.** Subsequent environments are not promoted automatically — see `recipes/deploy-and-promote.md`.

## Related recipes

- [`deploy-prebuilt-image.md`](deploy-prebuilt-image.md) — initial BYOI deploy
- [`build-from-source.md`](build-from-source.md) — source-build deploy (uses `workload.yaml` at build time)
- [`connect-components.md`](connect-components.md) — endpoint dependencies
- [`manage-secrets.md`](manage-secrets.md) — SecretReference patterns
- [`override-per-environment.md`](override-per-environment.md) — per-env replicas / resources / traits / env
- [`inspect-and-debug.md`](inspect-and-debug.md) — verify the change took effect
