---
name: openchoreo-developer-gitops
description: Application-developer GitOps work for OpenChoreo — onboarding Projects (with a ProjectType) and deploying their cell via ProjectReleaseBindings, onboarding Components (BYO image or source-build), authoring Workloads and `workload.yaml` descriptors, attaching PE-authored Traits, wiring component and Resource dependencies, generating ComponentReleases and ReleaseBindings via `occ` file-mode, authoring Resources + ResourceReleaseBindings by hand, promoting releases across Environments (single, project-wide, bulk), applying per-environment overrides, opening PRs upstream, and verifying Flux reconciliation. Use when the user says 'add a project to the GitOps repo', 'deploy my project cell', 'add a component to the GitOps repo', 'release my service via Git', 'use a database from my service', 'open a PR for this Workload change', 'promote to staging via Git', 'bulk-promote my project', 'roll back a release', or operates a developer-side change from inside a scaffolded GitOps repo.
metadata:
  version: "1.2.0"
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

If `occ` is missing, tell the user to install it. **If `occ` points at the wrong control plane, or `occ login` / `occ namespace list` fails**, configure it for the target before proceeding. Details: [CLI Configuration](https://openchoreo.dev/docs/platform-engineer-guide/cli-configuration) and [CLI Installation → Login](https://openchoreo.dev/docs/getting-started/cli-installation).

- **Repoint the shipped `default`** — every install ships a `default` control plane + context; if you only need occ on this one cluster, just update its URL and log in:
  ```bash
  occ config controlplane update default --url https://api.<cp-domain>
  occ login
  ```
- **Add a second control plane alongside an existing one** (e.g. keep a local k3d entry and add a remote cluster, switching between them with `occ config context use`) — `context add` requires **both** `--controlplane` and `--credentials`, each created first:
  ```bash
  occ config controlplane add <cp> --url https://api.<cp-domain>
  occ config credentials add <cp>
  occ config context add <cp> --controlplane <cp> --credentials <cp> --namespace <ns>
  occ config context use <cp> && occ login
  ```
- **Self-signed certs** (`x509: certificate is not trusted` on login) — trust the CA in your OS trust store (extract, then import per OS — see the CLI Installation doc):
  ```bash
  kubectl get secret openchoreo-ca-secret -n cert-manager \
    -o jsonpath='{.data.ca\.crt}' | base64 -d > openchoreo-ca.crt
  # macOS: sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain openchoreo-ca.crt
  ```

`occ login` is interactive (browser) — hand it to the user if you can't complete it.

If the cwd isn't a scaffolded repo (no `flux/` or `clusters/<name>/`, no `platform-shared/`, no `namespaces/`), ask the user for the repo path; if no repo exists, the repo needs scaffolding upstream of this skill — don't start creating components in a non-scaffolded directory.

**Always show the active `occ` context and confirm with the user** before any cluster-touching action.

## Step 1 — Load concepts (MANDATORY)

**Read [`references/concepts.md`](./references/concepts.md) in full before anything else.** Not optional, even if the task looks simple — you'll get the two-resource deploy model / immutability / workload-descriptor tradeoffs / verification ladder wrong from memory. Load once per session; if you catch yourself acting without it, stop and load now.

Load other references **on-demand**:

- [`references/authoring.md`](./references/authoring.md) — `occ` file-mode generators, docs lookup via `scripts/fetch-page.sh`, repo paths, git workflow, DCO.
- [`scripts/fetch-page.sh`](./scripts/fetch-page.sh) — fetch any OpenChoreo docs page by title (resolves against `llms.txt`, picks a stable version). Use this for full CRD schemas with optional fields; `--section "API Reference"` scopes matching to CRD-reference pages, `--list` dumps the index.
- [`references/getting-started.md`](./references/getting-started.md) — first-time deploys (no Project yet, or first time the user touches this repo).

## What this skill can do

- **Onboard a Project + deploy its cell** — scaffold the `Project` (with a `(Cluster)ProjectType`) and one `ProjectReleaseBinding` per env; deploy before its Components → [`recipes/deploy-project.md`](./references/recipes/deploy-project.md)
- **Onboard a Component** — BYO image or source-build → [`recipes/onboard-component-byo.md`](./references/recipes/onboard-component-byo.md), [`recipes/onboard-component-source-build.md`](./references/recipes/onboard-component-source-build.md)
- **Update a Workload** — edit YAML (BYO) or push + rebuild (source-build) → [`recipes/update-workload.md`](./references/recipes/update-workload.md)
- **Configure a Workload** — endpoints, env, files, secrets → [`recipes/configure-workload.md`](./references/recipes/configure-workload.md)
- **Attach a PE-authored Trait** → [`recipes/attach-trait.md`](./references/recipes/attach-trait.md)
- **Wire component dependencies** — `dependencies.endpoints[]` with env-var injection → [`recipes/connect-components.md`](./references/recipes/connect-components.md)
- **Use a Resource** — managed-infrastructure dependency (databases, queues, caches); author `Resource` + `ResourceReleaseBinding` YAML, wire `dependencies.resources[]` on a Workload → [`recipes/use-a-resource.md`](./references/recipes/use-a-resource.md)
- **Generate ComponentReleases / ReleaseBindings via `occ` file-mode** — produced through the onboard recipes.
- **Promote releases** — single component or bulk (project / all) → [`recipes/promote.md`](./references/recipes/promote.md), [`recipes/bulk-promote.md`](./references/recipes/bulk-promote.md)
- **Per-environment overrides** — replicas, resources, env vars, trait config → [`recipes/override-per-environment.md`](./references/recipes/override-per-environment.md)
- **Soft-undeploy / rollback** — flip `spec.state: Undeploy` or repoint at a prior `ComponentRelease` → [`recipes/promote.md`](./references/recipes/promote.md) *Rollback*
- **Verify Flux + ReleaseBinding reconciliation** → [`recipes/verify-and-debug.md`](./references/recipes/verify-and-debug.md)

## What this skill cannot do

- **Repo scaffolding or Flux wiring.** Out of scope; assumes the repo is already scaffolded and Flux is wired.
- **Authoring ProjectTypes / ComponentTypes / ResourceTypes / Traits / Workflows.** Platform-side. Pick from what `occ clusterprojecttype list` / `occ clustercomponenttype list` / `occ clusterresourcetype list` / `occ clustertrait list` / `occ clusterworkflow list` show; the developer references what the platform offers (a Project sets `spec.type` to one of them).
- **Plane registration, AuthzRole / SecretReference authoring.** Platform-side.
- **Imperative ops** — triggering a `WorkflowRun`, runtime log tail, pod-level debugging via `kubectl exec`. `WorkflowRun` does not go in Git (per `gitops/overview.md`); trigger via the UI, webhook, or `occ component workflow run`. For pod-level runtime debugging, use `kubectl` directly against the data plane or the cluster's observability backend.
- **Editing GitOps-managed resources via `occ apply -f` or any other direct write path** — Flux reverts them on the next reconcile. Always go through Git.

## Working style

- **Git is the source of truth.** Application resources change only through Git. `occ apply -f` is reserved for pre-Flux bootstrap (which is a PE concern; this skill rarely needs it).
- **Use `occ` file-mode generators for the four kinds they own** (Workload, ComponentRelease, ReleaseBinding, Component scaffold). For everything else (Project, dependency wiring on a Workload, ReleaseBinding overrides, Resource + ResourceReleaseBinding — no generators exist for these), fetch the full schema with `./scripts/fetch-page.sh --exact --title "<Kind>"`.
- **Always `git commit -s`** (DCO is required upstream; harmless on forks).
- **Every change is a feature branch + PR.** `git checkout -b <branch>` first, push that branch, open a PR.
- **`occ` over `kubectl` for OpenChoreo CRDs.** When reading / writing Project, Component, Workload, ComponentRelease, ReleaseBinding, Resource, ResourceRelease, ResourceReleaseBinding, Environment, ComponentType, ResourceType, Trait, Workflow, SecretReference — use `occ <kind> get/list/delete`. For runtime logs / build logs, prefer `occ component logs` / `occ workflowrun logs`. Reach for `kubectl` only for non-OpenChoreo resources (Flux CRDs, raw K8s pod state).
- **Verify, don't assume.** Reconciliation is interval-based (`GitRepository: 1m`, `Kustomization: 5m`). Read the result back with `occ <kind> get` after merge.
- **Don't open a PR or push without explicit user confirmation.** Local commits are reversible; remote-visible actions are not.
- **Path A vs Path B for source-build Workloads.** Decide once whether `workload.yaml` in the source repo is the source of truth (Path A) or direct edits to the Workload CR in the GitOps repo are (Path B). Mixing them is a one-way migration trap. See [`recipes/onboard-component-source-build.md`](./references/recipes/onboard-component-source-build.md).

## Stable guardrails

- **`ComponentRelease` is immutable.** Regenerate with `occ componentrelease generate`; never hand-edit.
- **`ResourceRelease` is auto-cut and never in Git.** The Resource controller hashes `Resource.spec + ResourceType.spec` and cuts a new release on every change. Promote a binding by advancing `ResourceReleaseBinding.spec.resourceRelease` in Git — do not use `occ resource promote` against a GitOps-managed cluster (it patches the binding imperatively and Flux reverts).
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
