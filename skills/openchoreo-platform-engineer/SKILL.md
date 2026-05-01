---
name: openchoreo-platform-engineer
description: |
  Use for OpenChoreo platform-level work: authoring ComponentTypes / Traits / Workflows (and cluster-scoped variants), creating Environments and DeploymentPipelines, registering DataPlanes / WorkflowPlanes / ObservabilityPlanes, configuring secret stores, identity, authorization roles, API gateway, alert notification channels, and Helm install / upgrade.
metadata:
  version: "1.3.0"
---

# OpenChoreo Platform Engineer Guide

Help with OpenChoreo platform-level work through the control-plane MCP server, with `kubectl` and Helm for cluster-native concerns. Keep this file lean, discover the live platform shape via MCP, and read detailed references only when the task actually needs them.

## Step 0 — Confirm MCP connectivity

Before reasoning about platform resources, verify the OpenChoreo control-plane MCP server is wired up. Run a cheap discovery call:

- `list_namespaces`

If the call succeeds (with whatever tool prefix your agent uses — see *Tool surface* below), you're connected. Proceed.

If the call fails with "tool not found" / "server not configured" / similar, the control-plane MCP server isn't reachable. **Stop and tell the user:**

> The OpenChoreo control-plane MCP server (`openchoreo-cp`) isn't configured for this session. Add it following the official guide — https://openchoreo.dev/docs/ai/mcp-servers/ — then re-run the request.

`kubectl` and Helm are still allowed — they're cluster-native and don't go through MCP — but for any OpenChoreo CRD, MCP is the first stop, so connectivity matters.

## Step 1 — Load the concepts reference

Before authoring or modifying any platform resource, read [`./references/concepts.md`](./references/concepts.md). It covers OpenChoreo's resource hierarchy, the Cell runtime model, endpoint visibility, planes, the API version OpenChoreo expects, and the per-task discovery-first workflow — facts the agent will reuse on every task. Memory of these is unreliable; the reference is short.

For each task you take on, also load the matching reference *before* acting on the task:

- **Authoring or updating a `ComponentType` / `ClusterComponentType` or a `Trait` / `ClusterTrait`** → [`./references/component-types-and-traits.md`](./references/component-types-and-traits.md).
- **Authoring or updating a `Workflow` / `ClusterWorkflow`** (CI build template or generic automation) → [`./references/workflows.md`](./references/workflows.md).
- **Writing CEL expressions** in templates / patches / validations → [`./references/cel.md`](./references/cel.md).
- **Authorization (`AuthzRole` / `ClusterAuthzRole` and bindings)** → [`./references/authz.md`](./references/authz.md).
- **Failure isolation across planes, controller / gateway / agent log inspection, gateway / route diagnostics** → [`./references/troubleshooting.md`](./references/troubleshooting.md).

For PE topics not bundled in these references — TLS / external CA, container registries, identity provider configuration, multi-cluster connectivity, deployment topology, observability adapter modules, API gateway modules, alert storage backend choice, IdP / bootstrap auth mappings, Helm upgrades — consult the official PE guide at **https://openchoreo.dev/docs/platform-engineer-guide/**. The docs are the source of truth for those topics; do not rely on memory.

## What this skill can do

These are the platform-engineering tasks this skill supports.

- **ComponentType / ClusterComponentType authoring** — schema, base workload type, resource templates, patches, validation rules, `allowedWorkflows` gating → [`component-types-and-traits.md`](./references/component-types-and-traits.md), [`recipes/author-a-componenttype.md`](./references/recipes/author-a-componenttype.md)
- **Trait / ClusterTrait authoring** — `creates[]` / `patches[]`, parameter schemas, environment-config overrides → [`component-types-and-traits.md`](./references/component-types-and-traits.md), [`recipes/author-a-trait.md`](./references/recipes/author-a-trait.md)
- **Workflow / ClusterWorkflow authoring** — Argo `runTemplate` shape, `allowedWorkflows` gating, ExternalRefs for secrets → [`workflows.md`](./references/workflows.md), [`recipes/author-a-ci-workflow.md`](./references/recipes/author-a-ci-workflow.md) for component-bound builds, [`recipes/author-a-generic-workflow.md`](./references/recipes/author-a-generic-workflow.md) for standalone automation
- **CEL expressions** in templates / patches / validations → [`cel.md`](./references/cel.md)
- **Authorization** — `AuthzRole` / `ClusterAuthzRole` and bindings → [`authz.md`](./references/authz.md)
- **Environment + DeploymentPipeline lifecycle** — create envs against existing planes, define linear / branching promotion paths → [`recipes/create-an-environment-and-promotion-path.md`](./references/recipes/create-an-environment-and-promotion-path.md)
- **Project + Namespace creation** — onboarding a new tenant namespace with a project, environments, and pipeline. Default to `default` namespace unless the user explicitly asks for a new one → [`recipes/bootstrap-a-namespace.md`](./references/recipes/bootstrap-a-namespace.md)
- **Pod-level diagnostics** — `get_resource_events`, `get_resource_logs` against a ReleaseBinding for app troubleshooting requested by a developer → [`troubleshooting.md`](./references/troubleshooting.md)
- **Cluster-native concerns** — Helm install / upgrade (control plane / planes / cluster-agent; upgrade order: control plane first), `ClusterSecretStore` / `SecretStore`, Argo `ClusterWorkflowTemplate`, Kubernetes Gateway API resources, raw controller / agent / gateway log inspection.
- **Troubleshooting platform-side failures** — failure isolation across planes, plane health checks, controller / gateway / agent logs → [`troubleshooting.md`](./references/troubleshooting.md)

## What this skill cannot do

- **Application-level work — `openchoreo-developer` owns this.** Authoring `Component` / `Workload` / `ReleaseBinding`, editing `workload.yaml`, attaching PE-authored Traits to a Component (`spec.traits[]`), tracing a runtime crash, deploying or promoting an app, debugging a developer-shape problem. **Pair this skill with `openchoreo-developer`** when the task crosses the boundary — many "this app fails to deploy" problems turn out to be a missing `ClusterTrait` or a misconfigured `DeploymentPipeline`. If both skills are available, run them together immediately.
- **GitOps workflows** — repo layout (`platform-shared/`, `namespaces/<ns>/platform/`), Flux CD setup, bulk promotion via Git, the `occ` file-system mode (`componentrelease generate`, `releasebinding generate`). A dedicated GitOps skill owns this; do not pull those flows into this skill.
- **Initial OpenChoreo install from scratch** — Helm install for a fresh control plane and first plane, Colima / k3d / GCP / multi-cluster bootstrap walkthroughs. **`openchoreo-install`** owns this. Once OpenChoreo is running, day-2 platform work comes back here.
- **Aggregated runtime log / metric / trace queries** — log search across replicas, metric queries, trace lookups, alert and incident queries. For pod-level evidence under a binding use `get_resource_events` / `get_resource_logs`; for longer-horizon history, fall back to `kubectl logs` against the relevant plane, or query the observability backend (Loki / Prometheus / Tempo) via its own UI / API when configured.
- **External-system operations** — IdP / Thunder / SSO admin work, external secret-backend admin (Vault / AWS Secrets Manager / OpenBao), Git provider configuration (webhooks, deploy keys), commercial WSO2 Choreo cloud resources, and incident state changes (acknowledge / resolve / RCA). When the user asks for one, say so plainly and direct them to the relevant system; explain the OpenChoreo-side pieces this skill *can* set up.

## Tool surface

Two surfaces: **MCP** (`openchoreo-cp` server) for OpenChoreo CRDs, and **`kubectl` / Helm** for cluster-native concerns (Helm install / upgrade, `ClusterSecretStore`, Argo `ClusterWorkflowTemplate`, Kubernetes Gateway API resources, raw controller / agent / gateway pod logs). The recipes name the right surface for each step.

> **Tool naming.** Throughout this skill, MCP tools are referenced by their bare name (e.g. `create_environment`). The actual callable name carries an agent-specific prefix wrapping the server name — Claude Code uses `mcp__openchoreo-cp__<tool>`. Other coding agents use different prefixes. Apply whatever your agent expects.

## Working style

The full per-task discovery flow is in `concepts.md` (loaded at *Step 1*). Durable principles to keep in mind:

- **Live cluster output beats memory.** Don't assume available ComponentTypes, Traits, Workflows, Environments, plane status, or field names — discover via MCP first.
- **Schema-first authoring.** Before writing a spec from scratch, fetch the creation schema (`get_component_type_creation_schema`, `get_trait_creation_schema`) or the resource schema (`get_*_schema`). MCP `create_*` / `update_*` calls take structured spec payloads, not YAML files — but the same schema applies.
- **`update_*` for ComponentType / Trait / Workflow is full-spec replacement.** `get_*` first, modify locally, send the complete spec back. Omitting a field deletes it.
- **MCP-first.** Reach for `kubectl` only when the operation is one of the gaps in *MCP write-surface gaps*, or for cluster-native CRDs.
- **Default to the `default` namespace.** Always ask before creating a new namespace — it's an organisational boundary, not a casual default.
- **Change one layer at a time** (Helm values → control-plane CRD → remote-plane resource → app-visible outcome). Don't fix an application symptom by guessing at platform internals.

## Reference routing

Foundational reference:

- [`./references/concepts.md`](./references/concepts.md) — resource hierarchy, Cell architecture, endpoint visibility, planes, API version, and the per-task discovery-first workflow. **Read before authoring anything** (per *Step 1*).

PE-specific references are linked inline from *What this skill can do* above — load the matching one before acting on its task. They live under `./references/`.

The 4 canonical Argo `ClusterWorkflowTemplate` YAMLs (`checkout-source`, `containerfile-build`, `publish-image`, `generate-workload`) ship at `./resources/workflow-templates/` and are applied via `kubectl apply -f` against the WorkflowPlane. Everything else is composed via MCP from `get_*_creation_schema` and the per-recipe guidance; no local YAML needed.

## Stable guardrails

- **`update_environment` is partial, but `data_plane_ref` is immutable.** Re-pointing an environment to a different plane requires delete + recreate (and re-binding any existing ReleaseBindings).
- **Helm upgrade order matters.** Control plane first, never move a remote plane ahead of it.
- **Scope matters.** Cluster-scoped and namespace-scoped resources are not interchangeable. `ClusterComponentType` may only reference `ClusterTrait` and `ClusterWorkflow`, not their namespace-scoped counterparts.
- **`status.conditions`, live resource YAML, and current controller logs are better truth sources than memory.** When a task needs exact controller behavior or CRD fields, inspect the repo or current docs instead of guessing.
- **Prefer reversible, inspectable changes** over broad edits across many planes or namespaces.

## Anti-patterns

- Loading every reference file before identifying the actual problem.
- Repeating stale examples without checking the current cluster or resource schema.
- Performing wide cluster sweeps before checking the affected object and logs.
- Treating app-level deployment symptoms as purely platform issues without checking the app resource chain.
- Making several platform changes at once and losing the causal signal.
- Creating a new namespace without asking the user — default to `default` unless explicitly told otherwise.
- Reaching for `kubectl` when an MCP tool exists for the operation.
- Sending a partial `update_component_type` / `update_trait` / `update_workflow` spec — the call replaces the whole spec; missing fields are deleted.
- Reaching for `occ` — this skill does not use the `occ` CLI. GitOps-style file-mode flows belong in the dedicated GitOps skill.
- Inventing observability tools that don't exist in this skill (`query_*` log/metric/trace/alert/incident tools). Use `kubectl logs` against the relevant plane, or query the observability backend's own UI.
