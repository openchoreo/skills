---
name: openchoreo-platform-engineer-gitops
description: Platform-engineer GitOps work for OpenChoreo — scaffolding a GitOps repo (pristine, platform-only, or active cluster), wiring Flux CD, and authoring platform CRDs (ComponentTypes, Traits, Workflows, Environments, DeploymentPipelines, SecretReferences, AuthzRoles, alert rules, notification channels) via Git. Use when the user says 'set up GitOps for this cluster', 'move this cluster to GitOps', 'wire Flux', 'add a ComponentType / Trait / Workflow via Git', or operates a platform change inside a scaffolded GitOps repo.
metadata:
  version: "2.0.0"
---

# OpenChoreo Platform-Engineer GitOps Guide

Git is the source of truth; the cluster is its reflection. This skill writes OpenChoreo **platform** resources to Git, lets Flux CD reconcile them, and reads cluster state with `occ` to verify.

This skill is scoped to platform-engineer GitOps work — initial scaffold + ongoing platform authoring. Application-level GitOps (Project / Component / Workload / ComponentRelease / ReleaseBinding) and non-GitOps cluster operations (Helm install, direct CRD edits) are out of scope; tell the user when a task crosses that boundary.

## Step 0 — Prerequisites

`occ` must be configured against the target cluster:

```bash
command -v occ && occ config context list      # occ configured?
occ namespace list                              # cluster reachable?
```

## Step 1 — Load concepts (MANDATORY)

**Read [`references/concepts.md`](./references/concepts.md) in full before anything else.** Not optional, even if the task looks simple — resource model / sync ordering / immutability / verification ladder / drift recovery are all easy to get wrong from memory. Load once per session; if you catch yourself acting without it, stop and load now.

Load other references **on-demand** as the task needs them:

- [`references/authoring.md`](./references/authoring.md) — where CRD shapes come from (live cluster / vanilla defaults / sample-gitops / `llms.txt`), repo path conventions, the cluster↔namespace scope swap, the CI-vs-GitOps workflow gotcha, git workflow, DCO.
- [`references/cel.md`](./references/cel.md) — only when writing or reviewing CEL inside ComponentType / Trait / Workflow templates.

## Detect the mode

```bash
{ ls flux 2>/dev/null || ls clusters 2>/dev/null; } \
  && { ls platform-shared 2>/dev/null || ls namespaces 2>/dev/null; }
```

- **Scaffolding mode** — cwd is empty or not yet a GitOps repo. Go to [`recipes/scaffold.md`](./references/recipes/scaffold.md). Covers pristine / platform-only / active-cluster paths.
- **Operating mode** — cwd has a Flux entrypoint (`flux/` for single-cluster, `clusters/<name>/` for multi-cluster) plus at least one of `platform-shared/` or `namespaces/`. Skip to the relevant author / install recipe.

If the heuristic doesn't fit the layout (per the docs' *Flexible Repository Structures* — repo-per-project, separate-releasebindings-repo, etc.), ask the user.

## What this skill can do

- **Scaffold a GitOps repo + wire Flux** — pristine, platform-only, or active cluster → [`recipes/scaffold.md`](./references/recipes/scaffold.md)
- **Install the default platform resources** — project / environments / pipeline / ComponentTypes / Traits + GitOps-mode build-and-release Workflows + Argo `ClusterWorkflowTemplate`s → [`recipes/install-defaults.md`](./references/recipes/install-defaults.md)
- **Install Flux + `git-token` / `gitops-token` secrets** when scaffolding finds them missing → [`recipes/install-flux-and-secrets.md`](./references/recipes/install-flux-and-secrets.md)
- **Author** a `(Cluster)ComponentType` / `(Cluster)Trait` / `(Cluster)Workflow` / `Environment` / `DeploymentPipeline` / `SecretReference` / `AuthzRole` (and binding) / `ObservabilityAlertRule` / `NotificationChannel` via Git → recipes under [`references/recipes/`](./references/recipes/)
- **Verify reconciliation; recover from drift** → [`recipes/verify-and-recover-drift.md`](./references/recipes/verify-and-recover-drift.md)

## What this skill cannot do

- **Application-level GitOps** — `Project` / `Component` / `Workload` / `ComponentRelease` / `ReleaseBinding` / workload-descriptor authoring. Out of scope; tell the user when the task crosses into application territory.
- **Helm install of the OpenChoreo control plane / planes.** Assumes a running control plane. See <https://openchoreo.dev/docs/getting-started/>.
- **Plane management in Git** — `DataPlane` / `ClusterDataPlane` / `WorkflowPlane` / `ClusterWorkflowPlane` / `ObservabilityPlane` / `ClusterObservabilityPlane` are one-time install-side setups with cert management. Out of scope by default; brief note in [`recipes/author-other-resources.md`](./references/recipes/author-other-resources.md) for users who insist.
- **Imperative ops** — triggering a `WorkflowRun`, `kubectl exec`, runtime log tail, direct CRD edits against the API server. `WorkflowRun` does **not** belong in Git; trigger via the UI, webhook, or `occ component workflow run`.
- **External-system admin** — Git provider webhooks, IdP / SSO, Vault / AWS Secrets Manager backend setup. The skill wires only the OpenChoreo-side `SecretReference` resources, not the upstream store.
- **CD tools other than Flux CD.**

## Tool surface

| Tool | Purpose |
| --- | --- |
| `occ` | Reads cluster state (`<kind> get`, `<kind> list`), authenticates (`login`, `config`), pre-Flux bootstrap (`apply -f` — single file). |
| `kubectl` | Context check, `apply -f flux/`, Argo `ClusterWorkflowTemplate` apply (workflow-plane), destructive cleanups after Flux reconciles. |
| `flux` | Verify `GitRepository` / `Kustomization` status, `flux reconcile`, `flux install`. |
| `git` + host CLI (`gh` / `glab` / `bb`) | Branch, `commit -s`, push, PR. |
| `WebFetch` / `git clone --depth 1` | Pull vanilla defaults and GitOps resources from upstream when scaffolding. URLs in [`references/authoring.md`](./references/authoring.md). |
| `AskUserQuestion` | Recipe-specific — used by scaffolding for repo decisions / per-category capture-or-skip / context confirmation, and by any recipe with destructive steps for before-push / before-Flux-wiring confirmations. |

## Working style

- **Git is the source of truth.** GitOps-managed resources change only through Git. `occ apply -f` and `kubectl apply -f` are reserved for pre-Flux bootstrap and out-of-Git cluster reads.
- **Flux prunes on delete.** If a resource was committed and is then removed from Git, the next reconcile deletes it from the cluster. Useful for retiring resources cleanly; dangerous if you commit accidentally.
- **Always `git commit -s`** (DCO). Default flow is PR + wait-for-merge; direct push only if the repo profile says so.
- **Verify, don't assume.** Reconciliation is interval-based (`GitRepository: 1m`, `Kustomization: 5m`); read the result back with `occ <kind> get` after merge.
- **Don't open a PR or push without explicit user confirmation.** Both are remote-visible.

## Stable guardrails

- **Sync ordering** — `platform-shared/` before `namespaces/<ns>/platform/` before `namespaces/<ns>/projects/`, via Flux `dependsOn`.
- **No plaintext secrets in Git** — use `SecretReference` resources backed by a `ClusterSecretStore`.
- **Protect `platform-shared/` with CODEOWNERS** — cluster-scoped changes affect every namespace. Sample at [`assets/codeowners-platform-shared`](./assets/codeowners-platform-shared).
- **Cluster ↔ namespace scope is interchangeable** for ComponentType / Trait / Workflow. Convert by swapping the `kind:` and adding/removing `metadata.namespace:`. Update referrers' `allowedWorkflows[].kind` accordingly. See [`authoring.md`](./references/authoring.md).
- **Vanilla CI workflows aren't GitOps-compatible.** `dockerfile-builder` / `paketo-buildpacks-builder` / `gcp-buildpacks-builder` / `ballerina-buildpack-builder` write the `Workload` CR directly to the cluster — Flux reverts it. Use the GitOps versions from `sample-gitops` instead. See [`authoring.md`](./references/authoring.md).

## Anti-patterns

- Scaffolding without confirming the `occ` + `kubectl` context — silently seeding the wrong cluster's resources into Git.
- Wiring Flux before the user has confirmed the remote URL — Flux will start pulling from somewhere unexpected.
- Pushing or opening a PR before the user has reviewed the commit list.
- Hand-authoring large CRDs (ComponentTypes / Workflows) from memory instead of fetching the shape from upstream or templating from a live `occ <kind> get`.
- Carrying vanilla CI workflows into a GitOps repo — they write directly to the cluster and conflict with Flux.
- Inventing tooling the user didn't ask for (kustomize overlays, custom controllers, helper scripts).
- Treating cluster reads as authoritative *after* GitOps is wired — once Flux is reconciling, Git is the source of truth.
