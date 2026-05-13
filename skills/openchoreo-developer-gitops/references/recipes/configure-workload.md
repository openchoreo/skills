# Recipe — Configure a Workload (env, files, endpoints, multi-container)

Beyond image + a single port. Covers env vars (literal + secret), config files (literal + secret-backed), endpoint visibility, multi-container shapes, and command / args.

## Shape

Two contexts:

- **Workload CR** (BYO, or source-build Path B) — lives at `namespaces/<ns>/projects/<project>/components/<component>/workload.yaml`. Fields: `spec.container.env[].key`, `spec.container.files[].key`, `spec.endpoints` (map keyed by name).
- **Workload descriptor** (source-build Path A) — lives at `<src-repo>/<appPath>/workload.yaml`. Fields: `configurations.env[].name`, `configurations.files[].name`, `endpoints[]` (list with `name` field).

Pick one path per component; **don't mix**.

Use [`../concepts.md`](../concepts.md) *Workload Descriptor* for the descriptor / CR field-name diff.

## Env vars

### Literal

```yaml
# Workload CR
spec:
  container:
    env:
      - key: LOG_LEVEL
        value: info
      - key: PORT
        value: "8080"                              # always a string in YAML
```

### Secret-backed (via PE-authored SecretReference)

The `SecretReference` is PE-authored. Discover with `occ secretreference list -n <ns>`. Inside the Workload:

```yaml
spec:
  container:
    env:
      - key: DB_PASSWORD
        valueFrom:
          secretKeyRef:
            name: db-credentials                   # SecretReference.metadata.name
            key: DB_PASSWORD                       # one of its data[*].secretKey values
```

> **Exactly one of `value` or `valueFrom`.** Both = validation fails. Neither = same.

### Descriptor form

```yaml
# Source-repo workload.yaml
configurations:
  env:
    - name: LOG_LEVEL
      value: info
  secrets:
    envs:
      - name: DB_PASSWORD
        remoteRef:
          key: db-credentials                       # or store path, depending on PE config
          property: DB_PASSWORD
```

Descriptor uses `configurations.env[].name` and `configurations.secrets.envs[]`. The build translates these to CR shape.

## File mounts

### Literal

```yaml
# Workload CR
spec:
  container:
    files:
      - key: /etc/app/config.json                  # absolute path inside the container
        mountPath: /etc/app/config.json
        value: |
          {"feature_x": false}
```

The platform creates a ConfigMap and mounts it. `key` is the container path; `mountPath` should match.

### Secret-backed

```yaml
spec:
  container:
    files:
      - key: /etc/app/secret.json
        mountPath: /etc/app/secret.json
        valueFrom:
          secretKeyRef:
            name: api-keys
            key: STRIPE_KEY
```

### Descriptor form

```yaml
configurations:
  files:
    - name: /etc/app/config.json
      mountPath: /etc/app/config.json
      value: |
        {"feature_x": false}
  secrets:
    files:
      - name: /etc/app/secret.json
        mountPath: /etc/app/secret.json
        remoteRef:
          key: api-keys
          property: STRIPE_KEY
```

## Endpoints

Always a map in the CR, keyed by endpoint name:

```yaml
spec:
  endpoints:
    http:
      type: HTTP
      port: 8080
      visibility: [external]
    grpc:
      type: gRPC
      port: 50051
      visibility: [project]                        # implicit; explicit form for clarity
    metrics:
      type: HTTP
      port: 9090
      visibility: [namespace]
```

Types: `HTTP`, `GraphQL`, `Websocket`, `gRPC`, `TCP`, `UDP`. Visibility: `project` (implicit) / `namespace` / `internal` / `external`.

### Endpoint with schema (HTTP)

```yaml
spec:
  endpoints:
    http:
      type: HTTP
      port: 8080
      visibility: [external]
      schema:
        type: REST
        content: |
          openapi: 3.0.0
          info:
            title: greeter
            version: 1.0.0
          paths:
            /hello:
              get:
                responses:
                  '200':
                    description: OK
```

Or reference an external schema file (the descriptor form supports inline + file reference; check the API ref).

### Descriptor form

```yaml
endpoints:
  - name: http
    type: HTTP
    port: 8080
    visibility: [external]
  - name: grpc
    type: gRPC
    port: 50051
    visibility: [project]
```

List with `name` field, not a map.

### `targetPort`

By default, `targetPort` defaults to `port`. Override when the container listens on a different port than the service exposes:

```yaml
endpoints:
  http:
    type: HTTP
    port: 80
    targetPort: 8080
    visibility: [external]
```

### `basePath`

For HTTP endpoints exposed externally, `basePath` becomes the path prefix in the gateway route:

```yaml
endpoints:
  http:
    type: HTTP
    port: 8080
    basePath: /api/v1
    visibility: [external]
```

The dependency consumer's `envBindings.address` injects the full URL including `basePath`.

## Multi-container

OpenChoreo Workloads support one container per Component by default. Multi-container workloads need a custom ComponentType from the PE that handles sidecars in `resources[]` templates. The Workload CR doesn't natively model multi-container — the ComponentType decides.

Check `occ clustercomponenttype get <name>` for the active platform's stance.

## Command / args

```yaml
spec:
  container:
    image: my-image:v1
    command: ["./app"]
    args: ["--config", "/etc/app/config.json"]
```

K8s semantics — `command` overrides `ENTRYPOINT`, `args` overrides `CMD`. Both optional; both omitted = use the image's defaults.

## Resources (limits / requests)

Resources don't live on the Workload — they live on the **ReleaseBinding** under `componentTypeEnvironmentConfigs.resources` (per-env), matching the ComponentType's `environmentConfigs.openAPIV3Schema`. See [`override-per-environment.md`](./override-per-environment.md).

Putting them on the Workload silently has no effect.

## Replicas

Same as resources — on the ReleaseBinding, under `componentTypeEnvironmentConfigs.replicas`. Per-env.

## Validation

Schema-side checks happen at admission. The full Workload schema:

```bash
./scripts/fetch-page.sh --exact --title "Workload"
```

Common admission failures:

- `Workload.spec.owner` doesn't match the Component's owner.
- `endpoints` carries duplicate keys (map collision).
- `env[].value` and `env[].valueFrom` both set.
- `dependencies.endpoints[].visibility` is `internal` or `external` (only `project` / `namespace` allowed for dep entries — target's visibility ≥ dep's).

## Related

- [`onboard-component-byo.md`](./onboard-component-byo.md), [`onboard-component-source-build.md`](./onboard-component-source-build.md)
- [`connect-components.md`](./connect-components.md) — `dependencies.endpoints[]` in detail
- [`override-per-environment.md`](./override-per-environment.md) — replicas / resources / per-env env vars
- [`../concepts.md`](../concepts.md) *Workload*, *Endpoint visibility*, *Dependencies*
