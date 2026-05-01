---
name: openchoreo-developer
description: |
  Use for application-level work on OpenChoreo: deploying and updating Components / Workloads / ReleaseBindings, triggering builds with available CI workflows, connecting components via endpoint dependencies, configuring env vars and secret references, promoting across Environments with per-environment overrides, and inspecting status / events / pod logs for troubleshooting.
metadata:
  version: "1.3.0"
---

# OpenChoreo Developer Guide

Help an application developer ship and operate a service on OpenChoreo through the control-plane MCP server. Keep this file lean, discover the live platform shape via MCP, and read detailed references only when the task actually needs them.

## Step 0 — Confirm MCP connectivity

Before reasoning about resources, verify the OpenChoreo control-plane MCP server is wired up. Run a cheap discovery call:

- `list_namespaces`

If the call succeeds (with whatever tool prefix your agent uses — see _Tool surface_ below), you're connected. Proceed.

If the call fails with "tool not found" / "server not configured" / similar, the control-plane MCP server isn't reachable. **Stop and tell the user:**

> The OpenChoreo control-plane MCP server (`openchoreo-cp`) isn't configured for this session. Add it following the official guide — <https://openchoreo.dev/docs/ai/mcp-servers/> — then re-run the request.

Do not attempt the rest of the task until MCP connectivity is confirmed; everything below assumes it.

## Step 1 — Load the concepts reference

Before authoring or modifying any resource, read [`./references/concepts.md`](./references/concepts.md). It covers OpenChoreo's resource hierarchy, the Cell runtime model, endpoint visibility, planes, and the API version OpenChoreo expects — facts the agent will reuse on every task. Memory of these is unreliable; the reference is short.

For each task you take on, also load the matching reference _before_ acting on the task:

- **First-time deploy of a new app or project** on this cluster (no Project yet, or first time the user has touched OpenChoreo) → load [`./references/getting-started.md`](./references/getting-started.md) first; it routes you into the right recipe.
- **Working with existing Components / Projects** (change image, update parameters, rebuild from source, modify workload, promote, troubleshoot) → skip getting-started; go directly to the matching recipe. To pick between the BYO and source-build recipes for an existing Component, call `get_component` and check the `workflow` field: present and non-empty → source-build ([`build-from-source.md`](./references/recipes/build-from-source.md)); absent or empty → BYO image ([`deploy-prebuilt-image.md`](./references/recipes/deploy-prebuilt-image.md)).
- A specific recipe — see _What this skill can do_ below; each task points at its recipe.

## What this skill can do

These are the application-developer tasks this skill supports through the OpenChoreo control-plane MCP server. Each entry points to its recipe where applicable.

- **Create and update Projects** — the organizational unit grouping related Components (becomes a Cell at runtime).
- **Create and update Components** — pick a ComponentType, set parameters.
  - BYO image: Component + Workload → [`deploy-prebuilt-image.md`](./references/recipes/deploy-prebuilt-image.md)
  - Source-build: Component referencing an available CI Workflow; trigger builds via `trigger_workflow_run` and follow the WorkflowRun → [`build-from-source.md`](./references/recipes/build-from-source.md)
- **Define and update Workloads** — container image, ports, endpoints, env vars, config files, file mounts, replicas → [`configure-workload.md`](./references/recipes/configure-workload.md)
- **Connect components** — declare endpoint dependencies between components (same-project or cross-project within the namespace); the platform injects connection details as env vars → [`connect-components.md`](./references/recipes/connect-components.md)
- **Consume secret references** — wire `SecretReference`s into env vars and files → [`manage-secrets.md`](./references/recipes/manage-secrets.md)
- **Deploy and promote across Environments** — bind a `ComponentRelease` to an Environment, then promote along the DeploymentPipeline → [`deploy-and-promote.md`](./references/recipes/deploy-and-promote.md)
- **Apply per-environment overrides** — replicas, resources, env vars, and trait config overrides on a ReleaseBinding → [`override-per-environment.md`](./references/recipes/override-per-environment.md)
- **Soft-undeploy and rollback** — flip a ReleaseBinding to `Undeploy`, or bind a prior `ComponentRelease` to roll back.
- **Check build status, logs, and events** — inspect a WorkflowRun's conditions, live logs, and per-task pod events.
- **Check deployment status and endpoints** — inspect a Component / ReleaseBinding's `status.conditions[]` and `status.endpoints[]`.
- **Check pod events and logs** under a ReleaseBinding for runtime debugging → [`inspect-and-debug.md`](./references/recipes/inspect-and-debug.md)
- **Discover available platform resources** — read ComponentTypes, Traits, Workflows, Environments, DeploymentPipelines, planes, SecretReferences. The developer sees what the platform has provisioned but does not author these.

## What this skill cannot do

These are platform-side tasks. When you hit one:

1. **Try to load the platform-engineer skill at `../openchoreo-platform-engineer/SKILL.md`** (relative to this skill's directory). If that file exists, read it and continue with both skills active — many real OpenChoreo problems straddle the boundary, and running both together is the right move.
2. **If the file isn't there** (the user installed only this skill, or doesn't have platform permissions), state the issue plainly and ask the user to escalate to a platform engineer who has the cluster access and tooling to do it.

Platform-side scope at a glance:

- Authoring or editing platform extensions — `ComponentType`, `Trait`, `Workflow` (and cluster variants).
- Environments, DeploymentPipelines, plane registration (DataPlane / WorkflowPlane / ObservabilityPlane), Helm install / upgrade.
- Authorization, gateway, secret store, registry, identity / IdP configuration.
- Observability platform setup (alert channels, alert rules, metric / trace / longer-horizon log queries).
- Runtime metrics, traces, alert/incident queries, and historical log search across replicas. Pod-level events and current container logs are still covered here via `get_resource_events` / `get_resource_logs`.

For the canonical platform-engineer scope and task catalog, see <https://openchoreo.dev/docs/platform-engineer-guide/>.

## Tool surface

This skill uses **one** MCP server: the OpenChoreo control plane.

| Server                          | Purpose                                                                            |
| ------------------------------- | ---------------------------------------------------------------------------------- |
| `openchoreo-cp` (control plane) | Resource CRUD, schema discovery, build triggers, deployment, pod-level events/logs |

> **Tool naming.** Throughout this skill, MCP tools are referenced by their bare name (e.g. `get_component`). The actual callable name carries an agent-specific prefix wrapping the server name — Claude Code uses `mcp__openchoreo-cp__<tool>`. Other coding agents use different prefixes. Apply whatever your agent expects.

## Working style

The full per-task discovery flow is in `concepts.md` (loaded at _Step 1_). Two durable principles to keep in mind:

- **Live cluster output beats memory.** Don't assume available ComponentTypes, Traits, Workflows, Environments, or field names — discover via MCP first.
- **Schema-first authoring.** Before writing a spec from scratch, fetch the schema (`get_workload_schema`, `get_cluster_component_type_schema`, `get_cluster_trait_schema`) or use a repo sample. MCP tools take structured spec payloads, not YAML files — but the same schema applies.

## Reference routing

Foundational references:

- [`./references/concepts.md`](./references/concepts.md) — resource hierarchy, Cell architecture, endpoint visibility, planes, API version, and the per-task discovery-first workflow. **Read before authoring anything** (per _Step 1_).
- [`./references/getting-started.md`](./references/getting-started.md) — load **only when deploying an app or project to OpenChoreo for the first time**: pre-flight namespace check, BYO vs source-build decision, picking a ComponentType, repo conventions for source-build, `autoDeploy` choice, and pointers to the right recipe. Skip this when working with existing Components.

Recipes are linked inline from _What this skill can do_ above — load the matching one before acting on its task. The recipes live under `./references/recipes/`.

The only file in `./assets/` is `workload-descriptor.yaml` — a starter template for the `workload.yaml` descriptor that source-build components keep at the root of their `appPath` in the source repo. It's a real artifact the user commits to their repo, not an input to MCP. Resource specs sent to MCP `create_*` / `update_*` calls are composed from schema discovery, not from asset files.

## Stable guardrails

Keep these because they are durable and routinely useful:

- All work goes through the control-plane MCP server. If a task can't be done with MCP, it crosses the platform/app boundary — hand off per _What this skill cannot do_.
- **For third-party / public apps: default to pre-built images (BYO), not source builds.** Source builds commonly fail because third-party Dockerfiles use multi-platform syntax (`ARG BUILDPLATFORM`) that OpenChoreo's buildah builder does not support. If a build exits 125 with a `BUILDPLATFORM` error, switch to BYO immediately.
- **Before deploying any third-party app: fetch the official Kubernetes or Helm manifests** and extract every required env var per service — dependencies inject service addresses but do not provide `PORT`, feature flags, or vendor SDK disable flags.

## Anti-patterns

- Running every discovery call before checking the resource already implicated.
- Writing Components or overrides from memory when `get_*_schema` and `get_*` MCP calls can reveal the current shape.
- Guessing deployed URLs or route formats instead of reading `ReleaseBinding.status.endpoints[]`.
- Treating a platform-side failure as an app-only problem after MCP evidence (status conditions, resource events, logs) points elsewhere.
- Creating source-build components (with `workflow`) for third-party apps that have pre-built images — this produces failed builds and clutters the UI; always check for pre-built images first.
- Omitting env vars from official manifests when deploying third-party apps — always fetch and apply the exact env vars the upstream manifests specify (`PORT`, feature flags, vendor SDK disable flags).
- Assuming a deployment is healthy because `status: Ready` without checking pod evidence — a crash-looping container can briefly appear Ready. Confirm with `get_resource_events` (restart counts, OOM kills, scheduling failures) and `get_resource_logs` (current container output) under the ReleaseBinding.
- Setting `visibility: external` on a service-to-service dependency between components in the same project — `project` is the right default. `external` is for public-internet ingress, not for internal wiring.
- Assuming dependency-injected service addresses are the only env vars needed — many apps also require `PORT`, telemetry disable flags, and optional service placeholders to start cleanly.
