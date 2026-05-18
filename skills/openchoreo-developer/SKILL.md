---
name: openchoreo-developer
description: Application-level OpenChoreo work via the control-plane MCP server — deploying services, configuring workloads, promoting releases, managing secret references, inspecting runtime. Use when the user says 'deploy my service', 'add a component', 'rebuild from source', 'promote to staging', 'rollback', or 'why is my pod crashing'.
metadata:
  version: "1.5.0"
---

# OpenChoreo Developer Guide

Help an application developer ship and operate a service on OpenChoreo through the control-plane MCP server. Discover the live platform shape via MCP; read detailed references only when the task needs them.

## Step 0 — Confirm MCP connectivity

Run `list_namespaces`. If the tool isn't reachable, tell the user the `openchoreo-cp` MCP server needs configuring per <https://openchoreo.dev/docs/ai/mcp-servers/> and stop.

## Step 1 — Load concepts (MANDATORY)

**Read [`./references/concepts.md`](./references/concepts.md) in full before anything else.** Not optional, even if the task looks simple — you'll get these wrong from memory. Load once per session; if you catch yourself acting without it, stop and load now.

Then load the matching reference for the task:

- **First-time deploy** (no Project yet, or first time touching OpenChoreo) → [`./references/getting-started.md`](./references/getting-started.md)
- **Working with existing Components** → straight to the matching recipe. To pick between BYO and source-build for an existing Component, `get_component` and check `spec.workflow`: present → [`build-from-source.md`](./references/recipes/build-from-source.md), absent → [`deploy-prebuilt-image.md`](./references/recipes/deploy-prebuilt-image.md).

## Step 2 — Load the PE skill for platform tasks

If the request touches `ComponentType` / `Trait` / `Workflow` (or cluster variants) or anything under *What this skill cannot do*, also load [`../openchoreo-platform-engineer/SKILL.md`](../openchoreo-platform-engineer/SKILL.md). If the PE skill isn't installed, escalate.

## What this skill can do

- **Projects** — create, update.
- **Components** — create, update, `patch_component` for `auto_deploy` / `parameters` / `traits` / `workflow` / metadata.
  - BYO image → [`deploy-prebuilt-image.md`](./references/recipes/deploy-prebuilt-image.md)
  - Source-build → [`build-from-source.md`](./references/recipes/build-from-source.md)
- **Workloads** — image, ports, endpoints, env vars, files → [`configure-workload.md`](./references/recipes/configure-workload.md)
- **Attach Traits** — pick from the platform's catalog → [`configure-workload.md`](./references/recipes/configure-workload.md)
- **Connect components** — endpoint dependencies; platform injects env vars → [`connect-components.md`](./references/recipes/connect-components.md)
- **SecretReferences** — CRUD + `secretKeyRef` consumption → [`manage-secrets.md`](./references/recipes/manage-secrets.md). The `ClusterSecretStore` is PE-owned.
- **Deploy and promote** — bind a `ComponentRelease` to an Environment, promote along the DeploymentPipeline → [`deploy-and-promote.md`](./references/recipes/deploy-and-promote.md)
- **Per-environment overrides** — replicas, resources, env vars, trait config on the ReleaseBinding → [`override-per-environment.md`](./references/recipes/override-per-environment.md)
- **Soft-undeploy / rollback** — `update_release_binding release_state: Undeploy`, or rebind to a prior `ComponentRelease`.
- **Hard-delete developer resources** — `delete_component`, `delete_workload`, `delete_release_binding`, `delete_project`, `delete_component_release`. Destructive; confirm first. **No `delete_namespace`** — PE-side.
- **Inspect runtime** — Component / ReleaseBinding `status.conditions[]` and `status.endpoints[]`; `get_resource_tree` to map a binding to its rendered K8s resources; `get_resource_events` / `get_resource_logs` for pod-level evidence; WorkflowRun logs and events → [`inspect-and-debug.md`](./references/recipes/inspect-and-debug.md)
- **Discover platform resources** (read-only) — ComponentTypes, Traits, Workflows, Environments, DeploymentPipelines, planes.

## What this skill cannot do

Platform-side work: authoring ComponentTypes / Traits / Workflows, Environments, DeploymentPipelines, planes, authorization, gateway / secret-store / IdP config, observability setup, longer-horizon log / metric / trace queries (pod-level events and current logs *are* covered via `get_resource_events` / `get_resource_logs`).

Load `../openchoreo-platform-engineer/SKILL.md` if it's installed; otherwise tell the user to escalate to a platform engineer. PE scope catalog: <https://openchoreo.dev/docs/platform-engineer-guide/>.

## Tool surface

One MCP server: `openchoreo-cp`. Throughout this skill, tools are referenced by bare name (e.g. `get_component`); your agent wraps with its prefix (Claude Code uses `mcp__openchoreo-cp__<tool>`).

ComponentType / Trait / Workflow and the plane tools are **scope-collapsed**: one tool with a `scope` arg — `"namespace"` (default) or `"cluster"` for the platform-wide `Cluster*` resource. This skill always uses the canonical name + `scope`. The old `*_cluster_*` names still exist as deprecated aliases (banner in v1.1, hidden in v1.2, removed in v1.3) and can be used alternatively against a v1.1 server — but prefer the canonical form.

## Working style

- **Live cluster output beats memory.** Discover via MCP first; don't guess available ComponentTypes / Traits / Workflows / Environments / field names.
- **Schema-first authoring.** `get_workload_schema`, or `get_component_type_schema` / `get_trait_schema` with `scope: "cluster"` for platform-wide standards, before writing a spec from scratch.

## Stable guardrails

- All work goes through the control-plane MCP server. If a task can't be done via MCP, it's platform-side — hand off.
- **Third-party / public apps: default to BYO image.** Source builds commonly fail on third-party Dockerfiles using `ARG BUILDPLATFORM` (exit 125). Switch to BYO immediately if you see it.
- **Before deploying any third-party app:** fetch the official manifests and extract every required env var — dependencies inject service addresses but not `PORT`, feature flags, or vendor SDK disable flags.

## Anti-patterns

- Running every discovery call before checking the resource already implicated.
- Writing specs from memory when `get_*_schema` / `get_*` can reveal the current shape.
- Guessing deployed URLs instead of reading `ReleaseBinding.status.endpoints[]`.
- Treating a platform-side failure as an app-only problem after the evidence points elsewhere.
- Creating source-build components for third-party apps that have pre-built images.
- Setting `visibility: external` on a service-to-service dependency in the same project — `project` is the default.
- **Treating `Ready=True` as "working".** Ready means reconciled, not functional. A crash-looping container can flap Ready, and a stable container can be Ready while misconfigured (env vars bound to wrong names, deps resolving to nowhere). Confirm with `get_resource_tree` → `get_resource_events` / `get_resource_logs` and an actual endpoint hit.
