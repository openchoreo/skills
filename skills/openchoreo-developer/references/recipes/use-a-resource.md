# Use a resource (managed-infrastructure dependency)

Wire a Component to a managed-infrastructure Resource (database, queue, cache, object storage) so OpenChoreo injects the resolved outputs as env vars or mounted files. Uses `spec.dependencies.resources[]` on the consuming Workload.

A Resource is the dev-facing handle on infrastructure — it references a platform-engineer-authored `ResourceType` / `ClusterResourceType`. The Resource itself is created by developers; per-environment deployment is wired by PE / GitOps via `ResourceReleaseBinding` (or by you, if your install allows it). See `concepts.md` → *Resource* for the model.

## Prerequisites

- The Resource exists in **the same Project** as the consumer Component (`ref` is a bare Resource name; cross-Project consumption isn't supported via this mechanism).
- The Resource has a `Ready` **`ResourceReleaseBinding`** in the consumer's environment. Without one, the consumer's `ReleaseBinding` flags `ResourceDependenciesReady=False, Reason=ResourceDependenciesPending`.
- The output names you bind exist on the underlying `ResourceType` — typos here are silent until reconcile and surface as `OutputNotResolved` reasons under `status.pendingResourceDependencies[]`.

Quick discovery sweep before authoring:

```yaml
list_resource_types                       # scope defaults to "namespace"
  namespace_name: default

list_resource_types                       # platform-wide types (postgres, valkey, nats…)
  scope: cluster

get_resource_type                         # read the type's outputs[]
  name: postgres
  scope: cluster

list_resources                            # what Resources already exist
  namespace_name: default
```

## Recipe

### 1. Pick / create the Resource

If a Resource already exists in your Project, use it (`get_resource` to inspect). Otherwise create one referencing a `ResourceType` you discovered above:

```yaml
get_resource_type_schema                  # fetch the parameter schema first
  name: postgres
  scope: cluster

create_resource
  namespace_name: default
  resource_spec:
    owner:
      projectName: orders
    type:
      kind: ClusterResourceType           # or ResourceType (namespace-scoped)
      name: postgres
    parameters:
      database: orders                    # values matching the type's parameter schema
```

The Resource controller cuts a `ResourceRelease` automatically; read the latest with `get_resource` → `status.latestRelease.name`.

### 2. Ensure a binding exists for the env

`Ready` binding == the resource is actually running in that env. If none exists, deploy it (or escalate to PE if your role can't):

```yaml
list_resource_release_bindings            # filter to bindings for this resource
  namespace_name: default
  resource_name: orders-db

# If no binding for the target env, create one:
create_resource_release_binding
  namespace_name: default
  resource_release_binding_spec:
    owner:
      projectName: orders
      resourceName: orders-db
    environment: development
    resourceRelease: orders-db-abc12345   # name from Resource.status.latestRelease.name
```

If your install routes Deploy through Backstage's UI, that maps to the same `create_resource_release_binding` call under the hood.

### 3. Read the consuming Workload

```yaml
get_workload
  namespace_name: default
  workload_name: order-service-workload
```

### 4. Add `dependencies.resources[]` and update

Send the full updated `workload_spec` with a new `dependencies.resources[]` block (preserve any existing `dependencies.endpoints[]`):

```yaml
update_workload
  namespace_name: default
  workload_name: order-service-workload
  workload_spec:
    owner: {projectName: orders, componentName: order-service}
    container: {...}                      # unchanged from the read
    endpoints: {...}                      # unchanged from the read
    dependencies:
      endpoints: [...]                    # unchanged from the read
      resources:
        - ref: orders-db                  # name of a Resource in the same Project
          envBindings:
            host: DB_HOST
            port: DB_PORT
            username: DB_USER
            password: DB_PASSWORD
            database: DB_NAME
          fileBindings:
            ca-cert: /etc/ssl/db-ca.pem
```

OpenChoreo resolves the outputs from `ResourceReleaseBinding.status.outputs[]` for the consumer's env and injects them into the container — env vars via the bound name, file mounts as a volume + volumeMount per `(ref, sourceKind, sourceName)`.

The update makes a new `ComponentRelease` (because the Workload spec changed) which auto-deploys if `autoDeploy: true`.

### 5. Verify after redeploy

Once the redeploy lands, verify in the order that actually catches errors:

1. **`get_release_binding`** → `status.conditions[]`:
   - `ResourceDependenciesReady=True` (the binding resolved outputs from a Ready provider).
   - `Ready=True`.
   If `ResourceDependenciesReady=False`, the breakdown sits on `status.pendingResourceDependencies[]` — see *Gotchas* for the common reasons.

2. **Hit the service.** A 200 from the consumer's external URL with the expected behavior (e.g., DB-backed endpoint returns real data) is the proof the wiring works.

3. **Container logs** if step 2 fails:

```yaml
get_resource_logs
  namespace_name: default
  release_binding_name: order-service-development
  pod_name: <pod-name-from-get_resource_tree>
```

Look for the env vars you bound (`DB_HOST`, etc.) in startup logs. Credential values are `valueFrom.secretKeyRef` — the kubelet resolves them inside the container, so you'll see references in the Pod spec but actual values only in the container's environment.

## Patterns

### Env-only consumption (most common)

```yaml
dependencies:
  resources:
    - ref: orders-db
      envBindings:
        host: DB_HOST
        port: DB_PORT
        username: DB_USER
        password: DB_PASSWORD
        database: DB_NAME
```

Works for all three output source kinds (`value`, `secretKeyRef`, `configMapKeyRef`). Sensitive outputs render as `valueFrom.secretKeyRef` in the Pod spec — the literal never round-trips through the control plane.

### File mounts for certs / CA bundles

```yaml
dependencies:
  resources:
    - ref: shared-mtls-ca
      fileBindings:
        ca.crt: /etc/ssl/ca/ca.crt        # ConfigMap-backed output → mounted file
        client.key: /etc/ssl/ca/client.key
```

`fileBindings` is only valid for outputs whose source kind is `secretKeyRef` or `configMapKeyRef`. A `value:` output has no DP-side object to mount and is rejected with `ErrInvalidFileBinding`.

The renderer dedupes volumes by `(ref, sourceKind, sourceName)` — multiple `fileBindings` into keys of the same Secret share a single volume with multiple mounts.

### Composite connection URL

When the consumer expects a single connection string (`postgres://user:pass@host:5432/db`), the ResourceType usually composes it data-plane-side and exposes it as one output (often called `url`). Bind that one:

```yaml
dependencies:
  resources:
    - ref: orders-db
      envBindings:
        url: DATABASE_URL                 # single composite output
```

The `postgres` / `nats` defaults under `samples/getting-started/cluster-resource-types/` use this pattern.

### Multiple resources

Up to 50 entries in `dependencies.resources[]` (separate limit from `dependencies.endpoints[]`):

```yaml
dependencies:
  resources:
    - ref: orders-db
      envBindings: {host: DB_HOST, port: DB_PORT, password: DB_PASSWORD}
    - ref: orders-cache
      envBindings: {host: REDIS_HOST, port: REDIS_PORT, password: REDIS_PASSWORD}
    - ref: orders-queue
      envBindings: {url: NATS_URL}
```

### Endpoint + Resource deps together

Both arrays coexist:

```yaml
dependencies:
  endpoints:
    - component: user-service
      name: http
      visibility: project
      envBindings:
        address: USER_SERVICE_URL
  resources:
    - ref: orders-db
      envBindings:
        host: DB_HOST
        password: DB_PASSWORD
```

The rendered Pod merges both kinds of bindings into `container.env` / `volumes` / `volumeMounts`.

## envBindings / fileBindings keys

```yaml
envBindings:
  <output-name>: <env-var-name>
fileBindings:
  <output-name>: <mount-path>
```

Each binding maps a `ResourceType` `output` name (left) to a name on the consumer container (right).

| Field | Maps to | Valid for output kind |
|---|---|---|
| `envBindings` | A container env var (resolved at pod start via `valueFrom.*` for ref-kind outputs) | `value`, `secretKeyRef`, `configMapKeyRef` |
| `fileBindings` | A mounted file at the path (volume + volumeMount synthesized) | `secretKeyRef`, `configMapKeyRef` only |

Discover available output names with `get_resource_type` → `spec.outputs[].name`. Look for the source kind on each output to know whether `fileBindings` is valid.

## Gotchas

- **`ref` is a Resource name in the same Project**, not a name of a `ResourceType`. The Resource is the dev-facing instance; the type is what the platform engineer authored. Confusing the two surfaces as `ResourceNotFound`.
- **`ResourceDependenciesReady=False, Reason=ResourceDependenciesPending`** is the most common error. Each entry on `status.pendingResourceDependencies[]` carries a free-form `reason` message (not an enum). Common message prefixes:
  - `"ResourceReleaseBinding not found for <project>/<ref> in environment <env>"` — no binding has been authored for this Resource in this env. Author one (`create_resource_release_binding`) or ask PE / GitOps to.
  - `"multiple ResourceReleaseBindings found for <project>/<ref> in environment <env>"` — duplicate bindings for the same `(resource, env)`. Delete the extras.
  - `"ResourceReleaseBinding <name> not ready"` — binding exists but its `Ready` condition isn't True. Drill in with `get_resource_release_binding` → `status.conditions[]`; the actual failure shows up as one of `RenderingFailed`, `ResourcesProgressing`, `ResourcesDegraded`, `ResourceApplyFailed`, or `OutputResolutionFailed` on `Synced` / `ResourcesReady` / `OutputsResolved`.
  - `"output not resolved on resource release binding: <output-name>"` — the binding is Ready but an output you bound isn't present on `status.outputs[]`. Confirm output names against `get_resource_type` → `spec.outputs[].name`.
  - `"output kind cannot be mounted as file: <output-name>"` — `fileBindings` references a `value:`-kind output. Only `secretKeyRef` / `configMapKeyRef` outputs can be mounted as files. Switch to `envBindings` for `value:` outputs.
- **A Resource is shared by every consumer in the same Project + Environment.** Editing `Resource.spec.parameters` cuts a new `ResourceRelease`; existing bindings stay pinned until promoted, but a new binding picks up the new release. Don't mutate `spec.parameters` for a one-consumer concern — that's what `ResourceReleaseBinding.spec.resourceTypeEnvironmentConfigs` is for (per-env override), or `workloadOverrides.env` on the consumer's `ReleaseBinding` (single-consumer per-env literal).
- **`update_workload` sends the full spec** — read first, append the resource dep, send back. Same gotcha as `connect-components.md`.
- **Dependency declaration is what shows the link in the cell topology.** An env var set only via `workloadOverrides.env` doesn't. If `envBindings` can't produce the exact name your app reads, bind to a dummy env var (e.g. `_DEP_DB_PASSWORD`) so the dependency stays visible, and set the real env var separately.
- **`autoDeploy: true` re-deploys on every `Workload` change.** Adding a resource dep cuts a new `ComponentRelease`, which deploys per the existing pipeline. Watch the binding transition `ReleaseSynced → ResourceDependenciesReady → ResourcesReady → Ready`.
- **`ResourceRelease` is immutable.** Promote = update `ResourceReleaseBinding.spec.resourceRelease` to a new release. Never hand-edit a `ResourceRelease`.
- **Resources are project-scoped.** Cross-project consumption isn't supported via `dependencies.resources[]` — you can't `ref: shared-db` to reach into another project. Either move the consumer Component into the Project that owns the Resource, or surface the resource as an endpoint dependency through a service Component that fronts it.
- **Don't manually mount volumes that the renderer synthesizes.** `fileBindings` produces `r-`-prefixed volume names (deterministic FNV hash); they're separate from `file-mount-*` volumes synthesized by `container.files[]`. Both lists merge into the rendered Pod automatically; don't reference the `r-*` names anywhere in your Workload spec.

## Related recipes

- [`connect-components.md`](connect-components.md) — endpoint dependencies on other components (different shape: `ref`-less, uses `component` + `name`)
- [`configure-workload.md`](configure-workload.md) — endpoint visibility, env vars, files (the `container.files[]` side; `fileBindings` from resources merges with these)
- [`deploy-and-promote.md`](deploy-and-promote.md) — promote a new `ResourceRelease` into an env by updating `ResourceReleaseBinding.spec.resourceRelease`
- [`override-per-environment.md`](override-per-environment.md) — per-env overrides via `resourceTypeEnvironmentConfigs` on the binding
- [`inspect-and-debug.md`](inspect-and-debug.md) — verify the env var injected and the connection succeeded
