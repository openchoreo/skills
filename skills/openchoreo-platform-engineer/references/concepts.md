# OpenChoreo Concepts

OpenChoreo is an open-source Internal Developer Platform (IDP) built on Kubernetes. Both developers and platform engineers interact primarily through the control-plane MCP server (`openchoreo-cp`). For build logs, longer-horizon log history, metrics, traces, alerts, or incidents, platform engineers drop to `kubectl logs` against the appropriate plane (workflow plane for Argo build pods, observability plane for fluent-bit / OpenSearch / observer). Platform engineers also fall back to `kubectl` for resources without an MCP write surface and for plane-internal CRDs and controller logs; developers stay in MCP and don't need direct cluster access.

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

The build's `generate-workload` step reads `workload.yaml` and emits a Workload CR (image + descriptor). Without `workload.yaml`, the auto-generated Workload contains only the image and has no routing. (This step runs inside the build pipeline — neither developers nor PEs invoke it directly.)

**Placement**: Must be at the root of the `appPath` directory. If `appPath` is `/backend`, place it at `/backend/workload.yaml`. Not the docker context root, not the repo root (unless `appPath` is `.`).

**Preferred enrichment path**: edit `workload.yaml` in the repo, commit, rebuild. The new workload spec flows through the build. Reach for `update_workload` MCP only when rebuilding isn't possible.

For the full descriptor schema and source-build flow, see `openchoreo-developer/references/recipes/build-from-source.md`.

### Endpoint Visibility

Controls who can reach your service:

- `project`: Same project and environment (implicit for all endpoints, no gateway needed)
- `namespace`: All projects in same namespace and environment (needs westbound gateway)
- `internal`: All namespaces in deployment (needs westbound gateway)
- `external`: Public internet (needs northbound gateway, usually configured)

The northbound gateway for external traffic is typically set up. The westbound gateway for internal/namespace traffic may not be. If you need internal visibility and get rendering errors, it's likely because the westbound gateway isn't configured. Escalate to platform engineering.

### ComponentType

Platform-engineer-defined template that controls how a component deploys. Developers pick from available types and fill in the schema. View available types with `list_cluster_component_types` and inspect one with `get_cluster_component_type` / `get_cluster_component_type_schema`. Authoring goes through MCP (`create_cluster_component_type` + `update_cluster_component_type`) or `kubectl apply -f` for big YAML edits — see `component-types-and-traits.md`.

**Workload types**: `deployment`, `statefulset`, `cronjob`, `job`, `proxy`

**Two kinds of parameters**:

- `parameters`: Static config, same everywhere the release deploys (e.g., image pull policy)
- `envOverrides`: The per-environment part of the ComponentType schema

ReleaseBinding supplies the actual per-environment values for that schema under `componentTypeEnvironmentConfigs`.

### Trait

Composable capability attached to components. Adds resources (like PVCs) or modifies existing ones (inject env vars, add volumes) without changing the ComponentType.

Each trait instance on a component needs a unique `instanceName`. This lets you attach the same trait type multiple times with different configs (e.g., two different persistent volumes).

View available traits: `list_cluster_traits`, `list_traits`. Inspect: `get_cluster_trait` / `get_cluster_trait_schema`.

**Common traits**: persistent-volume, ingress, autoscaling, resource-limits.

### Environment

A deployment target (dev, staging, prod). Maps to a DataPlane (Kubernetes cluster). View with `list_environments`. Create / update via `create_environment` / `update_environment` (note: `data_plane_ref` is immutable after creation).

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

Immutable snapshot of Component + Workload + ComponentType + Traits at a point in time. Like a lock file for deployments. Created automatically when `autoDeploy: true`, or manually with `create_component_release`. Discoverable via `list_component_releases`.

### ReleaseBinding

Binds a ComponentRelease to an Environment. This is what triggers actual deployment. Supports environment-specific overrides:

- `componentTypeEnvironmentConfigs`: Replicas, resource limits, etc.
- `traitEnvironmentConfigs`: Per-environment trait values keyed by trait `instanceName` (renamed from `traitOverrides` in v1.0.0).
- `workloadOverrides`: Extra env vars, files for specific environments
- `state`: `Active` (running) or `Undeploy` (removed)

### Workflow / WorkflowRun

Workflow is a build template defined by platform engineers (backed by Argo Workflows). WorkflowRun is an execution. Component workflows build container images from source; standalone workflows handle automation like migrations.

**How CI builds work**: When you trigger a build (`trigger_workflow_run` for component-bound, `create_workflow_run` for standalone), the workflow clones the repo, builds the image, then emits a Workload CR from `workload.yaml`. The controller picks this up and creates / updates the Workload resource. If `autoDeploy` is on, this triggers a new release and deployment. See `openchoreo-developer/references/recipes/build-from-source.md` for the full pipeline flow.

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

## Discovery-first workflow (per task)

For any individual platform task, follow these five phases in order. They're encoded as the agent's working style in `SKILL.md` and elaborated here.

### 1. Classify the task

Decide whether the work is:

- Pure platform work (this skill alone)
- App work that needs PE help (paired with `openchoreo-developer`)
- A mixed task that needs both OpenChoreo skills

For mixed tasks, keep the app-facing thread and the platform-facing thread connected. Many deployment failures are caused by an interaction between Component config and platform config.

### 2. Inspect current state via MCP first

Start with the smallest useful inspection:

- `get_component` / `get_workload` / `get_release_binding` for app-facing resources (status conditions, endpoints).
- `get_cluster_component_type` / `get_cluster_trait` / `get_cluster_workflow` for platform extensions.
- `list_environments`, `list_deployment_pipelines`, plane reads (`list_dataplanes`, `get_dataplane`, etc.) for topology.
- `get_resource_events` / `get_resource_logs` for pod-level debugging through a binding.

Drop to `kubectl logs` only when MCP can't reach what you need — controller pods, cluster-gateway, cluster-agent, or pods outside any OpenChoreo binding.

### 3. Fetch creation / resource schemas before authoring

Before writing a `spec` body for a `create_*` call, fetch the relevant schema:

- `get_component_type_creation_schema` / `get_cluster_component_type_creation_schema`
- `get_trait_creation_schema` / `get_cluster_trait_creation_schema`
- `get_workflow_creation_schema` / `get_cluster_workflow_creation_schema`
- `get_workload_schema`, `get_cluster_component_type_schema`, `get_cluster_trait_schema`, `get_cluster_workflow_schema` for inspecting existing-resource shape

For existing resources, read the current spec via `get_*` before sending an `update_*`. **`update_component_type`, `update_trait`, `update_workflow` (and cluster variants) are full-spec replacement** — read first, modify locally, send the complete spec back. Omitting a field deletes it. For one-line CEL or template tweaks, `kubectl apply -f` against an edited YAML is often easier; both paths produce the same end state.

### 4. Change one layer at a time

Platform tasks often span multiple layers:

- Helm install values
- Control-plane CRDs (Environment, DeploymentPipeline, ComponentType, etc.)
- Remote-plane resources (data-plane Gateway, ESO ClusterSecretStore, Argo ClusterWorkflowTemplate)
- App-visible outcomes (available types, workflows, route reachability)

Change the layer that is actually responsible, then re-check the dependent layers. Don't "fix" an application symptom by guessing at platform internals.

### 5. Verify with live evidence

Verification should come from the platform, not assumption:

- Resource conditions changed as expected (`get_*` → `status.conditions[]`).
- Controller / agent logs show the new state (`kubectl logs` against the relevant plane).
- Helm release and pod rollout are healthy.
- The downstream app-facing symptom is gone.

If the platform change succeeded but the app still fails, hand off to or continue with `openchoreo-developer`.
