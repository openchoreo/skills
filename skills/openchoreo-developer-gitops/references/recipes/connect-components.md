# Recipe — Connect Components via dependencies

A Component declares what it consumes from other Components via `Workload.spec.dependencies.endpoints[]`. The platform resolves the target endpoint's address and injects it as env vars on the consumer's container — no hardcoded hostnames, no guessing service DNS.

## Shape

```yaml
# Consumer's Workload (or descriptor)
spec:
  dependencies:
    endpoints:
      - component: backend-api
        name: api                                  # the target endpoint's name on backend-api
        visibility: project
        envBindings:
          address: BACKEND_URL                     # injects as $BACKEND_URL
```

Each entry:

- `component` — target Component name (required).
- `name` — target endpoint name on that Component (required).
- `visibility` — only `project` or `namespace` valid here. Target endpoint must declare at least this level (target's `visibility[]` ≥ dependency's).
- `project` — optional; defaults to the consumer's Project. Set explicitly for cross-Project (then `visibility` must be `namespace`).
- `envBindings` — maps connection pieces to env-var names. Keys: `address`, `host`, `port`, `basePath`. Any combination.

Up to 50 dependencies per Workload.

## Visibility levels for deps

| Visibility on target endpoint | Dep can use     | Notes                                          |
| ----------------------------- | --------------- | ---------------------------------------------- |
| (none — implicit `project`)   | `project`       | Same project, same env. Implicit on every endpoint. |
| `project`                     | `project`       | Same project, same env.                        |
| `namespace`                   | `project`, `namespace` | Same namespace, same env.               |
| `internal`                    | not valid for deps |                                            |
| `external`                    | not valid for deps |                                            |

> **Dependency entries reject `internal` and `external` `visibility`.** Cross-namespace dependencies are not supported via this mechanism — they require gateway / API-management configuration on the PE side.

## `envBindings` keys

| Key         | What gets injected                                                     | When to use                                   |
| ----------- | ---------------------------------------------------------------------- | --------------------------------------------- |
| `address`   | Full address — `scheme://host:port/basePath` for HTTP-style, `host:port` for gRPC / TCP / UDP. | Most common; ready-to-use URL.                |
| `host`      | DNS-resolvable hostname.                                               | When the app wants to build the URL itself.   |
| `port`      | Port number as string.                                                 | Pair with `host` for two-piece connection.    |
| `basePath`  | The target endpoint's `basePath`.                                      | When the consumer needs the path prefix separately. |

Mix and match:

```yaml
envBindings:
  host: DB_HOST
  port: DB_PORT
  # → both env vars injected
```

```yaml
envBindings:
  address: STRIPE_API_URL
  # → single env var with the full URL
```

## When the injected value doesn't match the consumer's expected format

`envBindings` covers most shapes (`address`, `host`, `port`, `basePath`). If the consumer expects something else — a connection-string DSN, a compound URL stitched from multiple pieces, a non-standard scheme — two ways to bridge:

### A. Stitch in the consumer's app code

Inject `host` and `port` (and any other parts) as separate env vars via `envBindings`; let the app construct the DSN at startup. Requires a small code change in the consumer, but no platform-side override.

```yaml
envBindings:
  host: DB_HOST
  port: DB_PORT
# Consumer app: const dsn = `postgres://user:pass@${process.env.DB_HOST}:${process.env.DB_PORT}/dbname`
```

### B. Per-environment override on the consumer's ReleaseBinding

Set a literal `value` in `workloadOverrides.env` per environment. Same `ComponentRelease` promotes cleanly; each binding carries its own value.

```yaml
# ReleaseBinding for staging
spec:
  workloadOverrides:
    env:
      - key: DATABASE_URL
        value: postgres://staging-host:5432/db
```

After the dep is deployed, read its address: `occ releasebinding get <dep>-<env> -n <ns>` → `status.endpoints[*].serviceURL.host` and `.port`. Compose the literal.

The first option (A) scales across environments and namespaces with no platform-side override; the second (B) is a shortcut for one-off / single-env work. Embedded credentials in either approach should still come from a `SecretReference` via `valueFrom.secretKeyRef`.

## Examples

### Same-project HTTP service

```yaml
# Consumer Workload
spec:
  dependencies:
    endpoints:
      - component: user-svc
        name: api
        visibility: project
        envBindings:
          address: USER_SERVICE_URL              # http://user-svc.<cell-ns>.svc.cluster.local:8080
```

The target endpoint on `user-svc`:

```yaml
endpoints:
  api:
    type: HTTP
    port: 8080
    visibility: [project]                       # implicit; explicit OK
```

### Cross-project, same-namespace (with namespace visibility)

```yaml
# Consumer Workload (in project-a)
spec:
  dependencies:
    endpoints:
      - project: project-b
        component: shared-api
        name: public
        visibility: namespace                   # required for cross-project
        envBindings:
          address: SHARED_API_URL
```

Target endpoint on `shared-api` must declare `visibility: [namespace]` (or `[project, namespace]`).

### Database dep

```yaml
spec:
  dependencies:
    endpoints:
      - component: postgres
        name: tcp
        visibility: project
        envBindings:
          host: DB_HOST
          port: DB_PORT
```

Consumer composes the DSN: `postgres://user:pass@${DB_HOST}:${DB_PORT}/dbname`.

### Multiple deps in one Workload

```yaml
spec:
  dependencies:
    endpoints:
      - component: postgres
        name: tcp
        visibility: project
        envBindings: { host: DB_HOST, port: DB_PORT }
      - component: nats
        name: tcp
        visibility: project
        envBindings: { address: NATS_URL }
      - component: user-svc
        name: api
        visibility: project
        envBindings: { address: USER_SERVICE_URL }
```

## Discovering what endpoints / components exist

```bash
occ component list -n <ns> -p <project>
occ workload get <component>-workload -n <ns> -o yaml | grep -A 20 endpoints
# Or:
occ component get <component> -n <ns>
```

For status.endpoints (the actual resolved URLs after deploy):

```bash
occ releasebinding get <component>-<env> -n <ns>
# status.endpoints[] shows the live serviceURL
```

## Gotchas

- **`visibility` on dep entries is restricted to `project` and `namespace`.** Cross-namespace requires gateways — PE side, not this mechanism.
- **Target endpoint visibility must be ≥ dep's visibility.** A `project`-only target can be consumed at `project` only; declaring `visibility: namespace` on the dep fails admission.
- **Up to 50 deps per Workload.** Hit this limit and you've got a monolith pretending to be microservices.
- **Dep values are injected at runtime,** after the target is deployed. Restart the consumer to pick up new dep values, or design the app to re-resolve.
- **`envBindings.address` is the full string** — including `scheme://` for HTTP. Logging it to stdout in plaintext means logs may leak the path.

## Related

- [`../concepts.md`](../concepts.md) *Dependencies*, *Endpoint visibility*
- [`configure-workload.md`](./configure-workload.md) — endpoints + env var basics
- [`onboard-component-byo.md`](./onboard-component-byo.md), [`onboard-component-source-build.md`](./onboard-component-source-build.md)
