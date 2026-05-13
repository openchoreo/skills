---
name: openchoreo-developer-gitops
description: Application-developer GitOps work for OpenChoreo — onboarding Components (BYO image or source-build), authoring Workloads and `workload.yaml` descriptors, attaching PE-authored Traits, wiring component dependencies, generating ComponentReleases and ReleaseBindings via `occ` file-mode, promoting releases across Environments (single, project-wide, bulk), applying per-environment overrides, opening PRs upstream, and verifying Flux reconciliation. Use when the user says 'add a component to the GitOps repo', 'release my service via Git', 'open a PR for this Workload change', 'promote to staging via Git', 'bulk-promote my project', 'roll back a release', or operates a developer-side change from inside a scaffolded GitOps repo.
metadata:
  version: "1.0.0"
---

# OpenChoreo Developer GitOps Guide

Git is the source of truth; the cluster is its reflection. This skill writes OpenChoreo **application** resources to Git (Project / Component / Workload / ComponentRelease / ReleaseBinding), lets Flux reconcile them, and reads cluster state with `occ` to verify.

This skill is scoped to application-developer GitOps work. Repo scaffolding, Flux wiring, and authoring platform CRDs (ComponentTypes, Traits, Workflows, Environments, DeploymentPipelines, SecretReferences, AuthzRoles, planes) are out of scope — they're done by whoever owns the platform side. Don't edit GitOps-managed resources via `occ apply -f` or any other direct write path; Flux will revert them on the next reconcile.

## Step 0 — Hard preconditions

Two checks; both must pass before proceeding.

```bash
# 0a — occ configured against the right cluster
command -v occ && occ config context list && occ namespace list

# 0b — cwd is inside a scaffolded GitOps repo
ls flux 2>/dev/null && ls platform-shared 2>/dev/null && ls namespaces 2>/dev/null
```

If `occ` is missing / unconfigured, stop and tell the user to install + configure it. If the cwd isn't a scaffolded repo (no `flux/` or `clusters/<name>/`, no `platform-shared/`, no `namespaces/`), ask the user for the repo path; if no repo exists, the repo needs scaffolding upstream of this skill — don't start creating components in a non-scaffolded directory.

**Always show the active `occ` context and confirm with the user** before any cluster-touching action.

## Step 1 — Load concepts (MANDATORY)

**Read [`references/concepts.md`](./references/concepts.md) in full before anything else.** Not optional, even if the task looks simple — you'll get the two-resource deploy model / immutability / workload-descriptor tradeoffs / verification ladder wrong from memory. Load once per session; if you catch yourself acting without it, stop and load now.

Load other references **on-demand**:

- [`references/authoring.md`](./references/authoring.md) — `occ` file-mode generators, docs lookup via `scripts/fetch-page.sh`, repo paths, git workflow, DCO.
- [`scripts/fetch-page.sh`](./scripts/fetch-page.sh) — fetch any OpenChoreo docs page by title (resolves against `llms.txt`, picks a stable version). Use this for full CRD schemas with optional fields. `./scripts/fetch-page.sh --list` dumps the full index.
- [`references/getting-started.md`](./references/getting-started.md) — first-time deploys (no Project yet, or first time the user touches this repo).

## What this skill can do

- **Onboard a Component** — BYO image or source-build → [`recipes/onboard-component-byo.md`](./references/recipes/onboard-component-byo.md), [`recipes/onboard-component-source-build.md`](./references/recipes/onboard-component-source-build.md)
- **Update a Workload** — edit YAML (BYO) or push + rebuild (source-build) → [`recipes/update-workload.md`](./references/recipes/update-workload.md)
- **Configure a Workload** — endpoints, env, files, secrets → [`recipes/configure-workload.md`](./references/recipes/configure-workload.md)
- **Attach a PE-authored Trait** → [`recipes/attach-trait.md`](./references/recipes/attach-trait.md)
- **Wire component dependencies** — `dependencies.endpoints[]` with env-var injection → [`recipes/connect-components.md`](./references/recipes/connect-components.md)
- **Generate ComponentReleases / ReleaseBindings via `occ` file-mode** — produced through the onboard recipes.
- **Promote releases** — single component or bulk (project / all) → [`recipes/promote.md`](./references/recipes/promote.md), [`recipes/bulk-promote.md`](./references/recipes/bulk-promote.md)
- **Per-environment overrides** — replicas, resources, env vars, trait config → [`recipes/override-per-environment.md`](./references/recipes/override-per-environment.md)
- **Soft-undeploy / rollback** — flip `spec.state: Undeploy` or repoint at a prior `ComponentRelease` → [`recipes/promote.md`](./references/recipes/promote.md) *Rollback*
- **Verify Flux + ReleaseBinding reconciliation** → [`recipes/verify-and-debug.md`](./references/recipes/verify-and-debug.md)

## What this skill cannot do

- **Repo scaffolding or Flux wiring.** Out of scope; assumes the repo is already scaffolded and Flux is wired.
- **Authoring ComponentTypes / Traits / Workflows.** Platform-side. Pick from what `occ clustercomponenttype list` / `occ clustertrait list` / `occ clusterworkflow list` show; the developer attaches what the platform offers.
- **Plane registration, AuthzRole / SecretReference authoring.** Platform-side.
- **Imperative ops** — triggering a `WorkflowRun`, runtime log tail, pod-level debugging via `kubectl exec`. `WorkflowRun` does not go in Git (per `gitops/overview.md`); trigger via the UI, webhook, or `occ component workflow run`. For pod-level runtime debugging, use `kubectl` directly against the data plane or the cluster's observability backend.
- **Editing GitOps-managed resources via `occ apply -f` or any other direct write path** — Flux reverts them on the next reconcile. Always go through Git.

## Working style

- **Git is the source of truth.** Application resources change only through Git. `occ apply -f` is reserved for pre-Flux bootstrap (which is a PE concern; this skill rarely needs it).
- **Use `occ` file-mode generators for the four kinds they own** (Workload, ComponentRelease, ReleaseBinding, Component scaffold). For everything else (Project, dependency wiring on a Workload, ReleaseBinding overrides), fetch the full schema with `./scripts/fetch-page.sh --exact --title "<Kind>"`.
- **Always `git commit -s`** (DCO is required upstream; harmless on forks).
- **Every change is a feature branch + PR.** `git checkout -b <branch>` first, push that branch, open a PR.
- **`occ` over `kubectl` for OpenChoreo CRDs.** When reading / writing Project, Component, Workload, ComponentRelease, ReleaseBinding, Environment, ComponentType, Trait, Workflow, SecretReference — use `occ <kind> get/list/delete`. For runtime logs / build logs, prefer `occ component logs` / `occ workflowrun logs`. Reach for `kubectl` only for non-OpenChoreo resources (Flux CRDs, raw K8s pod state).
- **Verify, don't assume.** Reconciliation is interval-based (`GitRepository: 1m`, `Kustomization: 5m`). Read the result back with `occ <kind> get` after merge.
- **Don't open a PR or push without explicit user confirmation.** Local commits are reversible; remote-visible actions are not.
- **Path A vs Path B for source-build Workloads.** Decide once whether `workload.yaml` in the source repo is the source of truth (Path A) or direct edits to the Workload CR in the GitOps repo are (Path B). Mixing them is a one-way migration trap. See [`recipes/onboard-component-source-build.md`](./references/recipes/onboard-component-source-build.md).

## Stable guardrails

- **`ComponentRelease` is immutable.** Regenerate with `occ componentrelease generate`; never hand-edit.
- **`Workload.spec.owner` (projectName + componentName) is immutable** after creation. Pick names carefully.
- **`Component.spec.componentType` and `spec.workflow` kinds default to cluster-scoped** when omitted. Set `kind: ComponentType` / `kind: Workflow` explicitly when referencing namespace-scoped variants.
- **`Project.spec.deploymentPipelineRef` is an object** (since v1.0.0), not a plain string. `kind` defaults to `DeploymentPipeline`.
- **For third-party / public apps: default to BYO image, not source build.** Multi-platform Dockerfiles (`ARG BUILDPLATFORM`) commonly fail in the buildah-based builder. If you see exit-125 `BUILDPLATFORM` errors, switch to BYO.
- **No plaintext secrets in Git.** Use a PE-authored `SecretReference`; consume from a Workload via `valueFrom.secretKeyRef`.
- **Workload `env` / `files` entries need exactly one of `value` or `valueFrom`** — not both, not neither. Validation fails otherwise.

## Anti-patterns

- Creating a Component without first reading the available `ClusterComponentType` / `ComponentType` / `Trait` / `Workflow` lists on the cluster. Author the spec against the live platform shape.
- Hand-authoring a Workload spec when `occ workload create --mode file-system` could do it from a descriptor + image.
- Hand-editing a `ComponentRelease` file (it's immutable; regenerate instead).
- Adding `workload.yaml` to a source repo whose Component's Workload has been iterated on directly (Path B) without first dumping the live Workload and reconstructing the descriptor (one-way destructive migration — overwrites the cluster spec).
- Setting `visibility: external` on a service-to-service dependency between Components in the same project — `project` is the right default. `external` is for public-internet ingress only.
- Pushing or opening a PR before the user has seen the commit list.
- Assuming a deployment is healthy because `Ready=True` — `Ready` means reconciled, not necessarily working. Curl an `external` endpoint or pull logs via `occ component logs <component> -n <ns> --env <env>` when in doubt.
