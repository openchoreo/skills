---
name: openchoreo-platform-engineer
description: Platform-level OpenChoreo work via the control-plane MCP server (plus `kubectl` and Helm) — authoring ComponentTypes / Traits / Workflows, creating Environments and DeploymentPipelines, registering Planes, configuring secret stores and authorization. Use when the user says 'set up a new environment', 'create a deployment pipeline', 'add a ComponentType', 'register a data plane', 'configure auth', or 'install OpenChoreo'.
metadata:
  version: "1.5.0"
---

# OpenChoreo Platform Engineer Guide

Help with OpenChoreo platform-level work through the control-plane MCP server, with `kubectl` and Helm for cluster-native concerns. Keep this file lean, discover the live platform shape via MCP, and read detailed references only when the task actually needs them.

## Step 0 — Confirm MCP connectivity

Run `list_namespaces`. If the tool isn't reachable, tell the user the `openchoreo-cp` MCP server needs configuring per <https://openchoreo.dev/docs/ai/mcp-servers/> and stop MCP-dependent OpenChoreo actions. `kubectl` and Helm remain usable for cluster-native CRDs.

## Step 1 — Load the concepts reference

Before authoring or modifying any platform resource, read [`./references/concepts.md`](./references/concepts.md). It covers OpenChoreo's resource hierarchy, the Cell runtime model, endpoint visibility, planes, the API version OpenChoreo expects, and the per-task discovery-first workflow — facts the agent will reuse on every task. Memory of these is unreliable; the reference is short.

For each task you take on, also load the matching reference *before* acting on the task:

- **Authoring or updating a `ComponentType` / `ClusterComponentType` or a `Trait` / `ClusterTrait`** → [`./references/component-types-and-traits.md`](./references/component-types-and-traits.md).
- **Authoring or updating a `Workflow` / `ClusterWorkflow`** (CI build template or generic automation) → [`./references/workflows.md`](./references/workflows.md).
- **Writing CEL expressions** in templates / patches / validations → [`./references/cel.md`](./references/cel.md).
- **Authorization (`AuthzRole` / `ClusterAuthzRole` and bindings)** → [`./references/authz.md`](./references/authz.md).
- **Failure isolation across planes, controller / gateway / agent log inspection, gateway / route diagnostics** → [`./references/troubleshooting.md`](./references/troubleshooting.md).

For PE topics not bundled in these references — TLS / external CA, container registries, identity provider configuration, multi-cluster connectivity, deployment topology, observability adapter modules, API gateway modules, alert storage backend choice, IdP / bootstrap auth mappings, Helm upgrades — consult the official PE guide at **<https://openchoreo.dev/docs/platform-engineer-guide/>**. The docs are the source of truth for those topics; do not rely on memory.

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

- **Application-level work — `openchoreo-developer` owns this.** Authoring `Component` / `Workload` / `ReleaseBinding`, editing `workload.yaml`, attaching PE-authored Traits to a Component via `patch_component traits: [...]`, managing `SecretReference` CRUD (`create_secret_reference` / `update_secret_reference` / `delete_secret_reference` — the underlying `ClusterSecretStore` is still PE-owned), hard-deleting developer-side resources (`delete_component` / `delete_workload` / `delete_release_binding` / `delete_project` / `delete_component_release` — but **`delete_namespace` is PE-side**, not exposed via MCP), tracing a runtime crash, deploying or promoting an app, debugging a developer-shape problem. **Pair this skill with `openchoreo-developer`** when the task crosses the boundary — many "this app fails to deploy" problems turn out to be a missing `ClusterTrait` or a misconfigured `DeploymentPipeline`. If both skills are available, run them together immediately.
- **Initial OpenChoreo install from scratch** — Helm install for a fresh control plane and first plane, Colima / k3d / GCP / multi-cluster bootstrap walkthroughs. **`openchoreo-install`** owns this. Once OpenChoreo is running, day-2 platform work comes back here.
- **Aggregated runtime log / metric / trace queries** — log search across replicas, metric queries, trace lookups, alert and incident queries. For pod-level evidence under a binding use `get_resource_events` / `get_resource_logs`; for longer-horizon history, fall back to `kubectl logs` against the relevant plane, or query the observability backend (Loki / Prometheus / Tempo) via its own UI / API when configured.
- **External-system operations** — IdP / Thunder / SSO admin work, external secret-backend admin (Vault / AWS Secrets Manager / OpenBao), Git provider configuration (webhooks, deploy keys), commercial WSO2 Choreo cloud resources, and incident state changes (acknowledge / resolve / RCA). When the user asks for one, say so plainly and direct them to the relevant system; explain the OpenChoreo-side pieces this skill *can* set up.

## Tool surface

Two surfaces: **MCP** (`openchoreo-cp` server) for OpenChoreo CRDs, and **`kubectl` / Helm** for cluster-native concerns (Helm install / upgrade, `ClusterSecretStore`, Argo `ClusterWorkflowTemplate`, Kubernetes Gateway API resources, raw controller / agent / gateway pod logs). The recipes name the right surface for each step.

> **Tool naming.** Throughout this skill, MCP tools are referenced by their bare name (e.g. `create_environment`). The actual callable name carries an agent-specific prefix wrapping the server name — Claude Code uses `mcp__openchoreo-cp__<tool>`. Other coding agents use different prefixes. Apply whatever your agent expects.

> **Scope-collapsed tools.** ComponentType / Trait / Workflow, the three plane families, and the Authz role / binding families are each a single tool that takes a `scope` arg — `"namespace"` (default; requires `namespace_name`) or `"cluster"` for the platform-wide `Cluster*` resource. This skill uses the canonical name + `scope`; e.g. `create_component_type` with `scope: "cluster"` authors a `ClusterComponentType`. The old `*_cluster_*` names still exist as deprecated aliases (banner in v1.1, hidden in v1.2, removed in v1.3) and can be used alternatively against a v1.1 server — prefer the canonical form.

## Working style

The full per-task discovery flow is in `concepts.md` (loaded at *Step 1*). Durable principles to keep in mind:

- **Live cluster output beats memory.** Don't assume available ComponentTypes, Traits, Workflows, Environments, plane status, or field names — discover via MCP first.
- **Schema-first authoring.** Before writing a spec from scratch, fetch the creation schema (`get_component_type_creation_schema`, `get_trait_creation_schema`) or the resource schema (`get_*_schema`). MCP `create_*` / `update_*` calls take structured spec payloads, not YAML files — but the same schema applies.
- **`update_*` for ComponentType / Trait / Workflow is full-spec replacement.** `get_*` first, modify locally, send the complete spec back. Omitting a field deletes it.
- **MCP-first.** Reach for `kubectl` only for cluster-native CRDs (Helm, `ClusterSecretStore`, Argo `ClusterWorkflowTemplate`, Kubernetes Gateway API) or when MCP doesn't expose a write path for the operation.
- **Default to the `default` namespace.** Always ask before creating a new namespace — it's an organisational boundary, not a casual default.
- **Change one layer at a time** (Helm values → control-plane CRD → remote-plane resource → app-visible outcome). Don't fix an application symptom by guessing at platform internals.

## Stable guardrails

- **`update_environment` is partial, but `data_plane_ref` is immutable.** Re-pointing an environment to a different plane requires delete + recreate (and re-binding any existing ReleaseBindings).
- **Helm upgrade order matters.** Control plane first, never move a remote plane ahead of it.
- **Scope matters.** Cluster-scoped and namespace-scoped resources are not interchangeable. `ClusterComponentType` may only reference `ClusterTrait` and `ClusterWorkflow`, not their namespace-scoped counterparts. On the scope-collapsed MCP tools this is the `scope` arg — `scope: "cluster"` operates on the `Cluster*` resource, `scope: "namespace"` (default) on the namespaced one.
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
- Inventing observability tools that don't exist in this skill (`query_*` log/metric/trace/alert/incident tools). Use `kubectl logs` against the relevant plane, or query the observability backend's own UI.
