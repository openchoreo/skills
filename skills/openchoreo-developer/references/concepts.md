# OpenChoreo Concepts

OpenChoreo is an open-source Internal Developer Platform (IDP) built on Kubernetes. Developers interact through the OpenChoreo control-plane MCP server (`openchoreo-cp`) and never need direct cluster access. Runtime evidence comes from the control-plane `get_resource_events` / `get_resource_logs` tools; for longer-horizon log/metric/trace history, escalate to the platform engineer. The platform abstracts away Kubernetes complexity while platform engineers control what's available.

## Resource Hierarchy

```text
Namespace (tenant boundary)
  ├── Project (bounded context / app domain)
  │     ├── Component (deployable unit)
  │     │     ├── Workload (runtime spec: image, ports, env, dependencies)
  │     │     ├── ComponentRelease (immutable snapshot)
  │     │     └── ReleaseBinding (deploys release to environment)
  │     ├── Resource (managed infrastructure: database, queue, cache)
  │     │     ├── ResourceRelease (immutable snapshot)
  │     │     └── ResourceReleaseBinding (deploys resource to environment)
  │     └── WorkflowRun (build execution)
  ├── Environment (dev/staging/prod, maps to DataPlane)
  ├── DeploymentPipeline (promotion paths between environments)
  └── SecretReference (external secret pointers)

Platform-managed (read-only for developers):
  ├── DataPlane (runtime cluster)
  ├── WorkflowPlane (CI/build cluster, formerly BuildPlane)
  ├── ObservabilityPlane (logging)
  ├── ComponentType / ClusterComponentType (deployment templates)
  ├── ResourceType / ClusterResourceType (infrastructure templates)
  ├── Trait / ClusterTrait (composable capabilities)
  ├── Workflow / ClusterWorkflow (build/automation templates)
  └── RenderedRelease (rendered deployment artifact on DataPlane)
```

## Core Abstractions

### Project

A bounded context grouping related components. At runtime, each Project becomes a **Cell** with its own isolated namespace, network policies, and security controls.

Components within a project communicate freely. Cross-project reachability is governed by endpoint visibility (see below).

**Example**: An e-commerce app might have "order-management" (order-service, payment-handler) and "user-management" (auth-service, profile-service) as separate projects.

### Component

A deployable unit. References a ComponentType that defines how it's deployed. Think of ComponentType as the blueprint and Component as a specific house built from it.

**Key fields**:

- `componentType`: Reference like `deployment/service` (format: `workloadType/typeName`)
- `owner.projectName`: Which project this belongs to
- `parameters`: Config values matching the ComponentType schema
- `traits`: Optional composable capabilities
- `autoDeploy`: When true, automatically creates releases when Workload changes
- `workflow`: Build configuration for source-to-image on current Component resources

**Example**: Each microservice, web frontend, or background job is a separate component.

### Workload

The runtime contract. Defines what image to run, what ports to expose, and what services to connect to.

**How it gets created**:

- **BYO image** (Component has no `spec.workflow`): the developer creates it explicitly via `create_workload`.
- **Source build** (Component has `spec.workflow`): the build's `generate-workload` step **auto-generates it**. The workload is always named `{component}-workload` — the build overrides any `metadata.name` from the descriptor. The build inlines `workload.yaml` from the source repo if present; otherwise the workload contains only the container image.

**Key fields**:

- `container`: image, command, args, env vars, files
- `endpoints`: Map of named network interfaces with type (`HTTP`, `GraphQL`, `Websocket`, `gRPC`, `TCP`, `UDP`) and visibility
- `dependencies.endpoints[]`: Connections to other components' endpoints, with automatic env var injection (renamed from `connections` in v1.0.0; nested under `dependencies.endpoints`, not flat at `dependencies`)

### Workload Descriptor

A `workload.yaml` file placed in your source repository — **the developer's source of truth** for the source-build component's runtime contract: endpoints, dependencies, env vars, file mounts, schemas. Hand-maintained, not auto-generated.

The build's `generate-workload` step reads `workload.yaml` and emits a Workload CR (image + descriptor). Without `workload.yaml`, the auto-generated Workload contains only the image and has no routing. (This step runs inside the build pipeline — developers don't invoke it directly.)

**Placement**: Must be at the root of the `appPath` directory. If `appPath` is `/backend`, place it at `/backend/workload.yaml`. Not the docker context root, not the repo root (unless `appPath` is `.`).

**Two ways to set / change the workload spec.** The choice is essentially *"is there a `workload.yaml` in the repo or not?"* — the build behaves differently in each case:

- **`workload.yaml` committed to the repo.** Every rebuild fully replaces the cluster Workload from the descriptor (a full `PUT`). All fields — endpoints, env, deps, files, container — are regenerated from `workload.yaml` plus the new image tag. **MCP edits to non-image fields are overwritten on the next rebuild.** Use this when the spec should be source-controlled and reviewable in PRs; treat the descriptor as the single source of truth.
- **No `workload.yaml`; spec lives only on the cluster.** First build creates a minimal Workload (image only). Subsequent `update_workload` calls via MCP add endpoints, env, deps, files — and **those persist**. On rebuild the build only patches `container.image`; every other field is preserved (`generate-workload.yaml` line ~190). Use this when you want fast iteration on the runtime contract without touching git, or when the spec hasn't stabilized.

A subtlety: **adding `workload.yaml` later is a one-way migration**. The first rebuild that finds it will full-PUT from it, replacing whatever's currently on the cluster (including any MCP-applied endpoints / deps / env). Migrate cleanly: dump current `get_workload` output, build the descriptor from that, commit, then rebuild.

Surface the choice to the user rather than picking silently.

For the descriptor schema and source-build flow, see `./recipes/build-from-source.md`.

### Endpoint Visibility

Controls who can reach your service. Declared as a *list* on each target endpoint (`endpoints.<name>.visibility: [...]`); every endpoint implicitly has `project`:

- `project`: Same project and environment (implicit for all endpoints)
- `namespace`: All projects in the same OpenChoreo namespace and environment
- `internal`: All OpenChoreo namespaces in the deployment
- `external`: Public internet — exposed through the platform's ingress gateway

"Namespace" here is the OpenChoreo (control-plane) namespace that holds the Project/Component resources — not a shared runtime namespace. Each Project runs in its own isolated Cell namespace at runtime; a cross-project `namespace`-visibility call still resolves because the platform routes it to the target's Cell.

`project` and `namespace` reachability is resolved by the platform within the data plane: a cross-project call at `namespace` visibility gets the target's in-cluster address injected, with no extra gateway setup. `external` is exposed through the platform's ingress gateway, which a standard install usually configures. If an endpoint you exposed doesn't resolve on your install, verify the data plane's gateway configuration rather than assuming the visibility is blocked.

> **Dependency entries are different.** When a Component declares a *dependency* on another component's endpoint (`dependencies.endpoints[*].visibility`), only `project` and `namespace` are valid — the API rejects `internal` and `external` there. Cross-namespace dependencies are not supported via this mechanism. See `recipes/connect-components.md`.

### ComponentType

Platform-engineer-defined template that controls how a component deploys. Developers pick from available types and fill in the schema. View available types with `list_component_types` and inspect one with `get_component_type` / `get_component_type_schema` — pass `scope: "cluster"` for the platform-wide ClusterComponentTypes most installs use.

**Component type format is `workloadType/typeName`** (e.g. `deployment/service`). Use `get_component_type_schema` (with `scope: "cluster"`) to discover accepted values before setting `spec.componentType.name`.

**Workload types**: `deployment`, `statefulset`, `cronjob`, `job`, `proxy`

**Two kinds of parameters**:

- `parameters`: Static config, same everywhere the release deploys (e.g., image pull policy)
- `envOverrides`: The per-environment part of the ComponentType schema

ReleaseBinding supplies the actual per-environment values for that schema under `componentTypeEnvironmentConfigs`.

### Trait

Composable capability attached to components. Adds resources (like PVCs) or modifies existing ones (inject env vars, add volumes) without changing the ComponentType.

Each trait instance on a component needs a unique `instanceName`. This lets you attach the same trait type multiple times with different configs (e.g., two different persistent volumes).

View available traits: `list_traits` (pass `scope: "cluster"` for the platform-wide ClusterTraits most installs use). Inspect: `get_trait` / `get_trait_schema`.

**Common traits**: persistent-volume, ingress, autoscaling, resource-limits.

### Environment

A deployment target (dev, staging, prod). Maps to a DataPlane (Kubernetes cluster). View with `list_environments`.

### DeploymentPipeline

Defines promotion paths between environments. A pipeline might be: development → staging → production.

**Important**: `deploymentPipelineRef` in Project spec is an **object** (changed in v1.0.0 — previously a plain string). `kind` is optional and defaults to `DeploymentPipeline`:

```yaml
# Both of these are valid
deploymentPipelineRef:
  name: default

deploymentPipelineRef:
  kind: DeploymentPipeline
  name: default

# Wrong - plain string no longer accepted
deploymentPipelineRef: default
```

### ComponentRelease

Immutable snapshot of Component + Workload + ComponentType + Traits at a point in time. Like a lock file for deployments. Created automatically when `autoDeploy: true`, or manually by binding a release to an environment via `create_release_binding`.

### ReleaseBinding

Binds a ComponentRelease to an Environment. This is what triggers actual deployment. Supports environment-specific overrides:

- `componentTypeEnvironmentConfigs`: Replicas, resource limits, etc.
- `traitEnvironmentConfigs`: Per-environment trait values keyed by trait `instanceName` (renamed from `traitOverrides` in v1.0.0).
- `workloadOverrides`: Extra env vars, files for specific environments
- `state`: `Active` (running) or `Undeploy` (removed)

### Resource

A managed-infrastructure dependency for the project — database, message queue, cache, object storage. References a ResourceType the way a Component references a ComponentType. Lives under a Project as a sibling of Component, not nested inside one. Same Resource is shared across all consumers in the same Project + Environment.

**Key fields**:

- `type`: `{ kind, name }` — `kind` is `ResourceType` or `ClusterResourceType`; `name` matches the template
- `owner.projectName`: Which project owns this resource
- `parameters`: Config values matching the ResourceType's schema (database size, instance class, etc.)

**Example**: A `postgres` Resource named `orders-db` consumed by `order-service` and `payment-handler` Components in the same Project.

Consumed by Components via `Workload.spec.dependencies.resources[].envBindings` / `.fileBindings` — the same shape as endpoint deps. The platform resolves outputs (host, port, credentials, connection strings) and injects them as env vars or mounted files on the consumer's container. Manage with `create_resource` / `get_resource` / `list_resources` / `delete_resource`; advance a release into an environment with the promote flow (see ResourceReleaseBinding below).

### ResourceType / ClusterResourceType

Platform-engineer-defined template for an infrastructure resource. Mirrors ComponentType: cluster-scoped or namespace-scoped, picked from the available types and filled in with `parameters`. View with `list_resource_types` — pass `scope: "cluster"` for platform-wide types (most installs ship `postgres`, `valkey`, `nats` as ClusterResourceTypes out of the box). Inspect with `get_resource_type` / `get_resource_type_schema`.

Each ResourceType declares `outputs[]` — named values that Resources of that type expose to consumers (e.g., `host`, `port`, `password`, `url`). Output kinds: literal `value`, `secretKeyRef`, or `configMapKeyRef`. Credentials never leave the data plane — only the reference (`{name, key}`) travels.

### ResourceRelease

Immutable snapshot of `{Resource, ResourceType}` at a point in time — the lock file for an infrastructure deploy, parallel to `ComponentRelease`. Named `{resource}-{hash}`. The Resource controller cuts a new release automatically whenever `Resource.spec` or the referenced template's spec changes. Read the latest release name from `Resource.status.latestRelease.name`.

### ResourceReleaseBinding

Binds a ResourceRelease to an Environment — deploys the resource on that env's data plane. One binding per Resource per environment. The Resource controller never fans these out automatically; each binding is authored explicitly via `create_resource_release_binding`, the Backstage UI's Deploy action, or a GitOps commit.

**Promote a new release into an environment** is a two-call flow: `get_resource` → read `status.latestRelease.name` → `update_resource_release_binding` with that name in `spec.resourceRelease`. Mirrors how component-side promotes update `ReleaseBinding.spec.releaseName`.

**Key fields**:

- `spec.resourceRelease`: Which `ResourceRelease` is pinned to this env. The promote knob.
- `spec.resourceTypeEnvironmentConfigs`: Per-env overrides (replica count, storage size, admin-tools-enabled flag, etc. — schema defined by the ResourceType).
- `spec.retainPolicy`: `Delete` (default) or `Retain`. Controls whether deleting the binding cascades the data-plane resource. PEs sometimes set `Retain` on prod for stateful infra.

**Status surfaces** `status.outputs[]` — the single source of truth for resolved outputs that consuming components read at render time. `Ready=True` aggregates `Synced`, `ResourcesReady`, and `OutputsResolved`.

### Workflow / WorkflowRun

Workflow is a build template defined by platform engineers (backed by Argo Workflows). WorkflowRun is an execution. Component workflows build container images from source; standalone workflows handle automation like migrations.

**How CI builds work**: When you trigger a build (`trigger_workflow_run`), the workflow clones your repo, builds the image, then generates a Workload CR from your `workload.yaml` descriptor (or just the image if no descriptor exists). The controller picks this up and creates/updates the Workload resource. If `autoDeploy` is on, this automatically triggers a new release and deployment. See `./recipes/build-from-source.md` for the full pipeline flow.

**Why workload.yaml exists**: A Dockerfile only describes how to build an image. It doesn't tell the platform what ports your app listens on, what protocol it speaks, or what other services it connects to. The `workload.yaml` descriptor fills this gap, declaring your app's runtime contract so the platform can generate the right routing, network policies, and service discovery.

### SecretReference

Points to secrets stored in an external secret store (like OpenBao or HashiCorp Vault). The platform syncs them into Kubernetes Secrets via External Secrets Operator. Workloads consume them via `valueFrom.secretKeyRef` — `container.env[].valueFrom.secretKeyRef` for environment variables, `container.files[].valueFrom.secretKeyRef` for file mounts.

## Cell Architecture (Runtime)

At runtime, each Project becomes a Cell. Components within a Cell communicate freely; reachability beyond the Cell is governed by endpoint `visibility`:

- `external` is exposed to the public internet through the platform's ingress gateway.
- `namespace` / `internal` make an endpoint reachable to other projects; the platform resolves these to in-cluster addresses.

You control this through endpoint `visibility` on Workloads. Gateways and network policy are configured by platform engineers on the DataPlane; what a given install supports is verifiable there.

## Deployment Flow

```text
Component → Workload → ComponentRelease → ReleaseBinding         → RenderedRelease (on DataPlane)
Resource             → ResourceRelease  → ResourceReleaseBinding → RenderedRelease (on DataPlane)
```

Component side:

1. Define Component (what to deploy, which type)
2. Define Workload (image, ports, dependencies) — manually or via build
3. ComponentRelease is created (immutable snapshot)
4. ReleaseBinding deploys release to environment
5. Platform renders templates, creates Kubernetes resources

For `autoDeploy: true` components, steps 3–4 happen automatically when the Workload changes.

Resource side (mirrors the component flow without the Workload step):

1. Define Resource (which infra, which type, what parameters)
2. Resource controller auto-cuts a `ResourceRelease` whenever `Resource.spec` or the referenced `ResourceType.spec` changes
3. Author one `ResourceReleaseBinding` per environment where the resource should run; promote later by updating `spec.resourceRelease`
4. Platform renders templates, creates Kubernetes resources on the data plane
5. Resolved outputs surface on `ResourceReleaseBinding.status.outputs[]`; consuming components pick them up via `dependencies.resources[]`

## Infrastructure Planes

These are platform-engineer managed. Developers see them as read-only.

- **Control Plane**: Runs OpenChoreo controllers and API server.
- **Data Plane**: Runs application workloads (can be multiple clusters).
- **WorkflowPlane**: Runs CI/CD builds (Argo Workflows; formerly called Build Plane).
- **Observability Plane**: Centralized logging (OpenSearch + Fluentbit).

## API Version

All OpenChoreo resources use: `apiVersion: openchoreo.dev/v1alpha1`.

## Inter-service Communication

Services within the same project can talk freely. For cross-project communication or formalized connections, use the Workload `dependencies` field instead of hardcoding URLs. The platform resolves service addresses and injects them as environment variables.

```yaml
dependencies:
  endpoints:
    - component: backend-api
      name: api                       # name of the target endpoint
      visibility: project
      envBindings:
        address: BACKEND_URL
```

This injects `BACKEND_URL` with the resolved address. No hardcoded hostnames, no guessing service DNS names. Note that connections live under `dependencies.endpoints[]`, not directly under `dependencies[]`.

**When the injected dependency value doesn't match the format the consumer expects.** The `envBindings` keys (`address`, `host`, `port`, `basePath`) cover the common shapes — but if the consumer expects something else (a connection-string DSN, a compound URL, a custom format stitched from multiple pieces, a non-standard scheme), `envBindings` alone won't get you there.

Two ways to bridge the gap:

- **Per-environment override on the consumer's ReleaseBinding.** Read the dep's live endpoint after it's deployed (`get_release_binding` → `status.endpoints[*].serviceURL.host` and `.port`), compose the value the consumer needs, and set it as a literal in `workloadOverrides.env` per environment. Same `ComponentRelease` promotes across envs cleanly; each binding carries its own value.
- **Stitch together in the consumer's app code.** Inject `host` and `port` (and any other parts) as separate env vars via `envBindings`; let the app construct the DSN at startup. No platform-side override needed. Requires a small code change in the consumer.

The first scales across environments and namespaces; the second is fine for one-off / single-env work but worth flagging to the user as a shortcut. Pick based on the situation. Embedded credentials in either approach should still come from a `SecretReference` via `valueFrom.secretKeyRef`.

## Resource Dependencies

To consume a managed-infrastructure Resource (database, queue, cache) from a Component, declare it under `Workload.spec.dependencies.resources[]`:

```yaml
dependencies:
  resources:
    - ref: orders-db           # name of a Resource in the same Project
      envBindings:
        host: DB_HOST
        port: DB_PORT
        username: DB_USER
        password: DB_PASSWORD
        database: DB_NAME
      fileBindings:
        ca-cert: /etc/ssl/db-ca.pem   # for secretKeyRef / configMapKeyRef outputs
```

- `ref` is the Resource name in the same Project (required, immutable).
- `envBindings`: maps a ResourceType `output` name → an env var name on the container.
- `fileBindings`: maps a ResourceType `output` name → a file mount path. The output's source kind must be `secretKeyRef` or `configMapKeyRef` (a literal `value:` output has no DP-side object to mount and will be rejected).

The platform resolves outputs from the consuming environment's `ResourceReleaseBinding.status.outputs[]` and injects them at render time. Credentials never round-trip through the control plane — the consumer pod gets a normal K8s `valueFrom.secretKeyRef` and the kubelet resolves it on the data plane.

A consumer is blocked while any referenced Resource has no Ready `ResourceReleaseBinding` in the consumer's environment. Failure shows as `ReleaseBinding.status.conditions[ResourceDependenciesReady] = False` with `Reason=ResourceDependenciesPending`, plus a per-entry breakdown in `status.pendingResourceDependencies[]`. Common causes: PE hasn't authored the binding for this env yet, the binding is pinned to a release whose outputs don't resolve, or the `ref` typo. See `./recipes/use-a-resource.md`.

The `ref` must name a Resource in the same Project (same `owner.projectName` as the consumer Component).

## Discovery-first workflow (per task)

For any individual developer task, follow these four phases in order. They're encoded as the agent's working style in the SKILL.md and elaborated here.

### 1. Inspect the repo and classify the app

Start by understanding what is being deployed:

- Services and runtimes
- Dockerfiles and build system
- ports, env vars, and inter-service dependencies
- whether the app fits a simple image-based path or a source-build path

Do not create or patch resources until the application shape is clear.

### 2. Discover only what this task needs

Use focused discovery via MCP instead of broad inventory:

- existing project, component, or release binding when names are known (`get_component`, `get_release_binding`)
- available ComponentTypes only if you need to create or change the type (`list_component_types`, `get_component_type_schema` — pass `scope: "cluster"` for platform-wide standards)
- available Workflows only if this is a source build (`list_workflows`, `get_workflow_schema` — pass `scope: "cluster"` for platform-wide ClusterWorkflows)
- environments and deployment pipelines only if deployment or promotion depends on them (`list_environments`, `list_deployment_pipelines`)

If the component already exists, inspect it (`get_component`, `get_workload`) before reauthoring.

### 3. Fetch schemas before authoring resource specs

Before writing a `workload_spec`, Component spec, or override payload, fetch the relevant schema:

- `get_workload_schema`
- `get_component_type_schema` (`scope: "cluster"` for platform-wide standards)
- `get_trait_schema` (`scope: "cluster"` for platform-wide standards)

For existing resources, read the current spec via `get_*` before sending an `update_*`. `update_workload` sends the full spec, not a partial patch — modifying locally then writing back is the canonical loop.

### 4. Verify with live app evidence

Use MCP to verify, in this order of specificity:

- `get_component` — `status.conditions[]`
- `get_release_binding` — per-environment readiness, deployed URLs
- `get_resource_events` — pod-level events under a binding (restart counts, scheduling failures, OOM kills)
- `get_resource_logs` — pod logs under a binding

Trust deployed URLs and endpoint details from `ReleaseBinding.status.endpoints[]` rather than constructing them by hand.

For deeper runtime queries — historical logs across replicas, metrics, traces, alerts, incidents — hand off per the developer skill's hand-off rule.
