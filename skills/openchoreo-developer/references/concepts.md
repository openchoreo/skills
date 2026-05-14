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
  │     └── WorkflowRun (build execution)
  ├── Environment (dev/staging/prod, maps to DataPlane)
  ├── DeploymentPipeline (promotion paths between environments)
  └── SecretReference (external secret pointers)

Platform-managed (read-only for developers):
  ├── DataPlane (runtime cluster)
  ├── WorkflowPlane (CI/build cluster, formerly BuildPlane)
  ├── ObservabilityPlane (logging)
  ├── ComponentType / ClusterComponentType (deployment templates)
  ├── Trait / ClusterTrait (composable capabilities)
  ├── Workflow / ClusterWorkflow (build/automation templates)
  └── RenderedRelease (rendered deployment artifact on DataPlane)
```

## Core Abstractions

### Project

A bounded context grouping related components. At runtime, each Project becomes a **Cell** with its own isolated namespace, network policies (Cilium), and security controls.

Components within a project communicate freely. Cross-project communication requires gateways, which platform engineers configure.

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

- `project`: Same project and environment (implicit for all endpoints, no gateway needed)
- `namespace`: All projects in same namespace and environment (needs westbound gateway)
- `internal`: All namespaces in deployment (needs westbound gateway)
- `external`: Public internet (needs northbound gateway, usually configured)

The northbound gateway for external traffic is typically set up. The westbound gateway for internal/namespace traffic may not be. If you need internal visibility and get rendering errors, it's likely because the westbound gateway isn't configured. Escalate to platform engineering.

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

### Workflow / WorkflowRun

Workflow is a build template defined by platform engineers (backed by Argo Workflows). WorkflowRun is an execution. Component workflows build container images from source; standalone workflows handle automation like migrations.

**How CI builds work**: When you trigger a build (`trigger_workflow_run`), the workflow clones your repo, builds the image, then generates a Workload CR from your `workload.yaml` descriptor (or just the image if no descriptor exists). The controller picks this up and creates/updates the Workload resource. If `autoDeploy` is on, this automatically triggers a new release and deployment. See `./recipes/build-from-source.md` for the full pipeline flow.

**Why workload.yaml exists**: A Dockerfile only describes how to build an image. It doesn't tell the platform what ports your app listens on, what protocol it speaks, or what other services it connects to. The `workload.yaml` descriptor fills this gap, declaring your app's runtime contract so the platform can generate the right routing, network policies, and service discovery.

### SecretReference

Points to secrets stored in an external secret store (like OpenBao or HashiCorp Vault). The platform syncs them into Kubernetes Secrets via External Secrets Operator. Workloads consume them via `valueFrom.secretKeyRef` — `container.env[].valueFrom.secretKeyRef` for environment variables, `container.files[].valueFrom.secretKeyRef` for file mounts.

## Cell Architecture (Runtime)

At runtime, each Project becomes a Cell. Traffic between cells flows through directional gateways:

- **Northbound**: Ingress from public internet → maps to `external` endpoint visibility
- **Southbound**: Egress to external services
- **Westbound**: Ingress from other cells within the org → maps to `internal` / `namespace` visibility
- **Eastbound**: Egress to other cells

As a developer, you control this through endpoint `visibility` on Workloads. The gateways themselves are configured by platform engineers on the DataPlane.

## Deployment Flow

```text
Component → Workload → ComponentRelease → ReleaseBinding → RenderedRelease (on DataPlane)
```

1. Define Component (what to deploy, which type)
2. Define Workload (image, ports, dependencies) — manually or via build
3. ComponentRelease is created (immutable snapshot)
4. ReleaseBinding deploys release to environment
5. Platform renders templates, creates Kubernetes resources

For `autoDeploy: true` components, steps 3–4 happen automatically when the Workload changes.

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
