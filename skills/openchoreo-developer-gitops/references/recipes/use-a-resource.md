# Recipe — Use a Resource via Git

Wire a Component to a managed-infrastructure Resource (database, queue, cache, object storage) so OpenChoreo injects resolved outputs as env vars or mounted files. All authoring happens via Git: commit `Resource` + `ResourceReleaseBinding` YAML, and add `dependencies.resources[]` to the consumer's Workload.

A `Resource` is the dev-facing handle on infrastructure. It references a PE-authored `ResourceType` / `ClusterResourceType`. The Resource itself is dev-owned (this skill); the `ResourceReleaseBinding` (one per env) is also committed from here.

## Shape

```yaml
# Consumer's Workload
spec:
  dependencies:
    resources:
      - ref: orders-db                              # name of a Resource in the same Project
        envBindings:
          host: DB_HOST                             # ResourceType output → env var name
          port: DB_PORT
          password: DB_PASSWORD
        fileBindings:
          ca-cert: /etc/ssl/db-ca.pem               # secretKeyRef / configMapKeyRef outputs only
```

Each entry:

- `ref` — name of a Resource in **the same Project** (required, immutable). Cross-Project consumption isn't supported via this mechanism.
- `envBindings` — maps a ResourceType `output` name → an env var name. Works for all three output kinds (`value`, `secretKeyRef`, `configMapKeyRef`).
- `fileBindings` — maps an output name → a file mount path. Only valid for `secretKeyRef` / `configMapKeyRef` outputs (a literal `value:` output has no DP-side object to mount).

Up to 50 entries in `dependencies.resources[]` (separate limit from `dependencies.endpoints[]`).

## Repo paths

```text
namespaces/<ns>/projects/<project>/
└── resources/<resource>/
    ├── resource.yaml                                # Resource CR
    └── release-bindings/                            # one ResourceReleaseBinding per env
        ├── <resource>-development.yaml
        ├── <resource>-staging.yaml
        └── <resource>-production.yaml
```

Sibling of the per-component layout; one directory per Resource. There's no `occ resource scaffold` or `occ resource generate` — hand-author the YAML (or copy from a sibling project as a template).

## Steps

### 1. Discover what's available

```bash
# Platform-wide ResourceTypes (postgres, valkey, nats ship by default)
occ clusterresourcetype list

# Namespace-scoped ResourceTypes for this tenant (if any)
occ resourcetype list -n <ns>

# Read outputs[] on the type you want to use
occ clusterresourcetype get postgres -o yaml | grep -A 30 outputs
```

If the type doesn't exist yet, escalate to PE — authoring `(Cluster)ResourceType` is platform-side.

### 2. Author the Resource

Fetch the parameter schema if you need it:

```bash
./scripts/fetch-page.sh --exact --title "ClusterResourceType"
# Or just inspect a sibling: cat namespaces/.../resources/<existing>/resource.yaml
```

```yaml
# namespaces/<ns>/projects/<project>/resources/orders-db/resource.yaml
apiVersion: openchoreo.dev/v1alpha1
kind: Resource
metadata:
  name: orders-db
  namespace: default
spec:
  owner:
    projectName: orders
  type:
    kind: ClusterResourceType                       # or ResourceType (namespace-scoped)
    name: postgres
  parameters:
    database: orders                                # values matching the type's parameter schema
```

`spec.type` and `spec.owner` are **immutable** — rename / re-point requires delete + recreate (which cascades on the data plane unless the binding's `retainPolicy: Retain`).

### 3. Author one ResourceReleaseBinding per env

The Resource controller cuts a `ResourceRelease` automatically (immutable, named `{resource}-{hash}`, not in Git). Pin a binding per env to deploy:

```yaml
# namespaces/<ns>/projects/<project>/resources/orders-db/release-bindings/orders-db-development.yaml
apiVersion: openchoreo.dev/v1alpha1
kind: ResourceReleaseBinding
metadata:
  name: orders-db-development
  namespace: default
spec:
  owner:
    projectName: orders
    resourceName: orders-db
  environment: development
  resourceRelease: orders-db-abc12345               # name from `occ resource get` after first reconcile
  resourceTypeEnvironmentConfigs:                   # per-env overrides (schema on the ResourceType)
    adminEnabled: true
  retainPolicy: Delete                              # Retain on prod for stateful infra
```

**First-pass authoring**: commit the binding with `spec.resourceRelease` unset; merge; read the latest release name from the cluster (`occ resource get orders-db -n <ns>`); commit a follow-up that fills `spec.resourceRelease`. Subsequent promotes just bump that field.

### 4. Wire the consumer Workload

Add `dependencies.resources[]` to the consumer's `Workload` (or to the `workload.yaml` descriptor for source-build components). For BYO components, edit the cluster `Workload` CR file:

```yaml
# namespaces/<ns>/projects/<project>/components/order-service/workload.yaml
spec:
  owner: {projectName: orders, componentName: order-service}
  container:
    image: ghcr.io/.../order-service:abc
    env: [...]                                      # unchanged
  endpoints: {...}                                  # unchanged
  dependencies:
    endpoints: [...]                                # unchanged
    resources:
      - ref: orders-db
        envBindings:
          host: DB_HOST
          port: DB_PORT
          username: DB_USER
          password: DB_PASSWORD
          database: DB_NAME
```

For source-build components, edit `workload.yaml` in the **source repo**, not in the GitOps repo — the descriptor key shape uses `configurations.*` for env / files and `dependencies.resources[]` for resource deps. The next build emits the Workload CR from the descriptor.

### 5. Regenerate ComponentRelease + ReleaseBinding(s)

The Workload spec changed, so the existing `ComponentRelease` is stale. For BYO:

```bash
occ componentrelease generate \
  --mode file-system \
  --root-dir <repo> \
  --project orders \
  --component order-service

occ releasebinding generate \
  --mode file-system \
  --root-dir <repo> \
  --project orders \
  --component order-service \
  --env development                                  # or omit --env to regen all
```

For source-build, the build pipeline regenerates these on the next push.

### 6. Commit + verify

Branch + PR. After merge:

```bash
# Flux pulled + applied
flux get kustomizations -A

# Resource exists and cut a release
occ resource get orders-db -n <ns>
# status.latestRelease.name populated; status.conditions[Ready]=True

# Binding is Ready (Synced → ResourcesReady → OutputsResolved → Ready)
occ resourcereleasebinding get orders-db-development -n <ns>
# status.outputs[] populated with declared output names

# Consumer's binding picked up the dep
occ releasebinding get order-service-development -n <ns>
# status.conditions[ResourceDependenciesReady]=True
```

If `ResourceDependenciesReady=False`, read `status.pendingResourceDependencies[]` for the per-entry reason (see *Gotchas* below).

### 7. Promote across envs

When the Resource changes (`spec.parameters` edit in Git → controller cuts a new release), promote per env by bumping `spec.resourceRelease` in each binding YAML.

```bash
occ resource get orders-db -n <ns> -o jsonpath='{.status.latestRelease.name}'
# orders-db-def67890
```

```yaml
# namespaces/<ns>/projects/<project>/resources/orders-db/release-bindings/orders-db-staging.yaml
spec:
  resourceRelease: orders-db-def67890                # was orders-db-abc12345
```

Commit, PR, merge. Flux reconciles, RRB controller re-renders, DP rolls. Same shape as bumping a `ComponentRelease` reference on a `ReleaseBinding`.

> **`occ resource promote`** is an imperative shortcut that patches the binding directly on the cluster. **Don't use it on a GitOps-managed cluster** — Flux reverts the change on the next reconcile. Promote via Git.

## Examples

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

Sensitive outputs (`secretKeyRef` / `configMapKeyRef` source kind) render as `valueFrom.secretKeyRef` / `.configMapKeyRef` in the rendered Pod spec — literal values stay on the data plane.

### File mounts for certs / CA bundles

```yaml
dependencies:
  resources:
    - ref: shared-mtls-ca
      fileBindings:
        ca.crt: /etc/ssl/ca/ca.crt
        client.key: /etc/ssl/ca/client.key
```

`fileBindings` is only valid for outputs whose source kind is `secretKeyRef` or `configMapKeyRef`. The renderer dedupes volumes by `(ref, sourceKind, sourceName)`.

### Composite connection URL

```yaml
dependencies:
  resources:
    - ref: orders-db
      envBindings:
        url: DATABASE_URL                            # single composite output exposed by the type
```

The shipped `postgres` / `nats` defaults expose a `url` output that composes the full connection string data-plane-side.

### Endpoint + Resource deps together

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

Both arrays coexist and merge into the rendered Pod's `env` / `volumes` / `volumeMounts`.

## `envBindings` / `fileBindings` keys

```yaml
envBindings:
  <output-name>: <env-var-name>
fileBindings:
  <output-name>: <mount-path>
```

| Field | Maps to | Valid for output kind |
| --- | --- | --- |
| `envBindings` | A container env var (resolved at pod start via `valueFrom.*` for ref-kind outputs) | `value`, `secretKeyRef`, `configMapKeyRef` |
| `fileBindings` | A mounted file at the path (volume + volumeMount synthesized) | `secretKeyRef`, `configMapKeyRef` only |

Discover available output names with `occ <clusterresourcetype|resourcetype> get <name> -o yaml` → `spec.outputs[].name`. The source kind on each output determines whether `fileBindings` is valid.

## Discovering Resources in a Project

```bash
occ resource list -n <ns>                            # all Resources in the namespace
occ resource list -n <ns> --project orders           # filter by Project
occ resource get orders-db -n <ns> -o yaml           # full spec + status.latestRelease

# Bindings for a Resource
occ resourcereleasebinding list -n <ns> --resource orders-db
```

## Gotchas

- **`ref` is a Resource name in the same Project**, not a `ResourceType` name. The Resource is the dev-facing instance; the type is what the platform engineer authored. Confusing them surfaces as `ResourceNotFound`.
- **`ResourceDependenciesReady=False, Reason=ResourceDependenciesPending`** is the most common error on the consumer side. Read `status.pendingResourceDependencies[]` for the per-entry reason:
  - `NotFound` — `ref` doesn't match a Resource in this Project.
  - `NoBindingForEnv` — Resource exists but no `ResourceReleaseBinding` in the consumer's env. Commit the binding.
  - `ProviderNotReady` — binding exists but isn't `Ready`. Check `occ resourcereleasebinding get` for the actual failure.
  - `OutputNotResolved` — binding is Ready but the output you bound doesn't exist on the type, or its CEL didn't evaluate. Confirm output names against the ResourceType.
  - `InvalidFileBinding` — `fileBindings` references a `value:`-kind output (only `secretKeyRef` / `configMapKeyRef` can be mounted).
- **The Resource is shared by every consumer in the same Project + Environment.** Editing `Resource.spec.parameters` cuts a new release; existing bindings stay pinned until promoted. Don't mutate it for a one-consumer concern — use `ResourceReleaseBinding.spec.resourceTypeEnvironmentConfigs` (per-env override) or `workloadOverrides.env` on the consumer's `ReleaseBinding` (single-consumer per-env literal).
- **`spec.resourceRelease` empty = nothing deployed.** A binding committed without `spec.resourceRelease` set is valid but doesn't deploy until you fill it. The two-step "commit empty, then fill" is intentional — the first reconcile cuts the release, then you advance the binding.
- **`Resource.spec.type` and `Resource.spec.owner` are immutable.** Renaming or re-pointing requires delete + recreate. With `retainPolicy: Delete` on the binding, that cascades the data-plane object (potentially destroying data). For stateful infra, set `retainPolicy: Retain` on the binding before deleting.
- **`ResourceRelease` is immutable and auto-cut.** Never hand-edit; never commit one to Git. The Resource controller produces them; the binding's `spec.resourceRelease` is what you advance.
- **`occ resource promote` is imperative — don't use it on GitOps-managed clusters.** Patches the binding directly against the cluster API; Flux reverts on the next reconcile. Promote via Git.
- **Cross-project consumption isn't supported.** You can't `ref: shared-db` to reach into another project. Either move the consumer Component into the Project that owns the Resource, or have that Project expose a service Component fronting the Resource (then use `dependencies.endpoints[]`).
- **`fileBindings` synthesizes `r-`-prefixed volumes** via FNV hash. They merge automatically with `file-mount-*` volumes from `container.files[]`. Don't reference the `r-*` names anywhere in your Workload spec.
- **For source-build, edit `workload.yaml` in the source repo, not the cluster Workload CR.** The descriptor's `dependencies.resources[]` shape mirrors what lands on the CR. Mixing edits (descriptor + CR) on a source-build component is a one-way migration trap; see [`onboard-component-source-build.md`](./onboard-component-source-build.md).

## Related

- [`../concepts.md`](../concepts.md) *Resource*, *ResourceType*, *ResourceRelease*, *ResourceReleaseBinding*, *Resource dependencies*
- [`connect-components.md`](./connect-components.md) — endpoint dependencies (different shape: `component` + `name` + `visibility`)
- [`configure-workload.md`](./configure-workload.md) — env vars, files, the `container.files[]` side
- [`promote.md`](./promote.md) — promote pattern for ComponentRelease (resource side mirrors via `spec.resourceRelease` bump)
- [`override-per-environment.md`](./override-per-environment.md) — `resourceTypeEnvironmentConfigs` per env
- [`verify-and-debug.md`](./verify-and-debug.md) — diagnose `Ready=False` and binding failures
