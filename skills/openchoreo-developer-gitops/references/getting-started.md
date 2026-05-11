# Getting started

**Load this when deploying an app / project to OpenChoreo via GitOps for the first time** — no Project yet in the repo, or first time the user has touched this repo. It walks you through orientation (what's already provisioned, BYO vs source-build, which ComponentType, repo conventions) and routes you into the right recipe.

**Skip this when working with existing Components** — for image bumps, parameter updates, rebuilds, promotion, troubleshooting → go directly to the matching recipe. This file is the orientation that wraps the first deploy.

Pair this with [`./concepts.md`](./concepts.md). Concepts always; getting-started only on first-time deploys.

## 0. Is the agent inside the source repo as well?

Before pre-flight, check whether the agent is operating inside the git repo for the application source code being deployed, **in addition to** the GitOps repo (the user might have both clones in the workspace).

Heuristics:

- The cwd is the GitOps repo (per the Step 0b check in SKILL.md).
- A separate directory in the workspace is the source repo — usually obvious from the user's framing ("here's the source code for the greeter service") or from a path like `<workspace>/<service-name>/Dockerfile`.

**If yes:** the agent can also write `workload.yaml` into the source repo (for source-build flow), open PRs in both repos, etc. Coordinate two PRs (source + GitOps) with the user's explicit approval per step.

**If no:** the agent only operates on the GitOps repo. For source-build, the user manages the source repo themselves and the workflow's `repository.url` points at it.

## Up-front questions

Ask interactively, not as a wall of text. In Claude Code, use `AskUserQuestion` with explicit options.

- **BYO image or source-build?** Default to source-build *only* if the agent is in the source repo (per §0); otherwise default to BYO. Third-party / public apps: always BYO (multi-platform Dockerfiles commonly fail in the buildah builder).
- **If source-build:** which CI Workflow? `occ clusterworkflow list` / `occ workflow list -n <ns>`. The right one depends on the source build system:
  - Dockerfile present → `docker-gitops-release` (or `dockerfile-builder` for non-GitOps flows).
  - Clean source (no Dockerfile) → `google-cloud-buildpacks-gitops-release` or similar buildpacks workflow.
  - React / SPA → `react-gitops-release`.
- **If BYO, how does the image get built?**
  - **External CI** (GitHub Actions, GitLab CI, …) — confirm trigger + registry + tag scheme.
  - **Manual** — the user runs `docker build` / `docker push` themselves. Confirm registry + repo + tag style. The agent won't run `docker push` without explicit per-iteration approval.
  - **Hybrid / unsure** — treat as manual until clarified.
- **Deploy scope:** first environment only, or auto-promote along the DeploymentPipeline?
- **`autoDeploy`:** every push lands in dev (`true`), or human gate even for the first env (`false`)?

### Persist the answers

Save the choices in the repo root's `CLAUDE.md` (or `AGENTS.md`) under `## OpenChoreo deploy choices`. Future sessions read this and skip the questions.

Useful things to capture: component name, project, ComponentType chosen, BYO vs source-build, CI workflow name, external-CI trigger command (for BYO), `autoDeploy` choice, target environments.

## 1. Pre-flight discovery — what does this namespace already provide?

Before authoring any application resource, confirm what the PE has provisioned in the target namespace.

```bash
# Namespace
occ namespace list                              # confirm target namespace exists

# Environments + pipelines
occ environment list -n <ns>                    # at least one must exist
occ deploymentpipeline list -n <ns>             # at least one must exist

# Platform types (cluster + namespace scoped — discover both)
occ clustercomponenttype list
occ componenttype list -n <ns>

occ clustertrait list
occ trait list -n <ns>

occ clusterworkflow list
occ workflow list -n <ns>

# Existing projects (to decide where the new component goes)
occ project list -n <ns>

# Planes for completeness
occ clusterdataplane list
```

If any required prereq is missing (no ComponentTypes, no Environments, no DataPlane), this is a platform-side concern and out of scope for this skill. Tell the user and stop.

## 2. Code discovery — infer the workload contract

When inside the source repo (per §0), walk the code to figure out what the workload actually needs at runtime. The output feeds either the `workload.yaml` descriptor (source-build) or the Workload spec passed to `occ workload create` (BYO).

Read for:

- **Endpoints** — `app.listen(8080)`, `http.ListenAndServe(":3000", ...)`, `uvicorn ... --port 8080`, framework defaults; `EXPOSE` in Dockerfile; protocol (HTTP / gRPC / GraphQL / Websocket / TCP / UDP).
- **Dependencies** — HTTP / gRPC clients in source pointing at other services; `redis://`, `postgres://`, `nats://` connection strings; env-driven addresses (`process.env.USER_SERVICE_URL`).
- **Required env vars** — `process.env.X`, `os.Getenv("X")`, config schemas (Pydantic settings, Viper, dotenv, framework `application.properties`).
- **Config files / mounted assets** — `fs.readFileSync('/etc/...')`, hard-coded mount paths, runtime `config.json` reads (common in SPAs).

For repos with multiple services, do this per-service. A service with no inbound endpoints (worker / cron job) → empty endpoints list is fine.

## 3. Confirm the workload contract with the user

Before authoring `workload.yaml` or calling `occ workload create`, present what §2 inferred and ask the user to confirm or correct. Catching a wrong dependency or missed env var here is cheaper than after the first failed deploy.

Show a tabular summary, one block per service:

```text
Service: <component-name>
  Endpoints:
    - <name> (<type>, port <port>) — visibility: <project|namespace|internal|external>
  Dependencies:
    - <target-component>.<endpoint>  →  injected as $<ENV_VAR_NAME>
        (evidence: <file:line>)
  Required env vars:
    - <name> = <literal | "from SecretReference X" | "from dependency injection">
  Config files mounted:
    - <mountPath> = <source: inline | from SecretReference | from descriptor file>
```

Ask explicitly via `AskUserQuestion`. Each ambiguous item is one question.

- **Dependency mapping complete?** Inferred maps often miss feature-flagged clients and service-mesh DNS deps.
- **Dependency *target* names right?** A client variable named `userService` in source might map to a Component named `user-svc` on the cluster.
- **Visibility levels OK?** Public-facing frontends need `external`; service-to-service deps default to `project`.
- **Which env vars come from a `SecretReference`?** API keys, tokens, DB passwords → SecretReference (PE-authored; pick from `occ secretreference list -n <ns>`). PORT, feature flags → literal.
- **Anything missing?** Always end with this.

## 4. Pick a deployment shape

### BYO image (prebuilt container image)

- Resources to create: `Component` (no `spec.workflow`) **plus** `Workload`.
- Recipe: [`./recipes/onboard-component-byo.md`](./recipes/onboard-component-byo.md).
- Best for: third-party / public apps, monorepos where CI lives elsewhere, ad-hoc images.

### Source-build (OpenChoreo builds from a Git repo)

- Resources to create: `Component` with `spec.workflow` referencing a `ClusterWorkflow` / `Workflow`. The build creates `{component}-workload`; **don't** call `occ workload create`.
- Recipe: [`./recipes/onboard-component-source-build.md`](./recipes/onboard-component-source-build.md).
- Best for: first-party code where you want OpenChoreo's build pipeline to manage image lifecycle.

> **Third-party / public apps: default to BYO.** Source builds commonly fail on third-party Dockerfiles because they use `ARG BUILDPLATFORM` multi-stage syntax that the buildah-based builder does not support. If you see exit code 125 with a `BUILDPLATFORM` error, switch to BYO immediately.

## 5. Pick a ComponentType

The `componentType` reference (`<workloadType>/<name>`) determines what K8s resources the platform generates. Common shapes:

| ComponentType                  | Use for                                                      |
| ------------------------------ | ------------------------------------------------------------ |
| `deployment/service`           | Backend HTTP / gRPC / TCP services                           |
| `deployment/web-application`   | Public-facing frontends (SPAs, server-rendered web apps)     |
| `deployment/worker`            | Background workers, queue consumers                          |
| `deployment/database`          | Stateful stores when running as deployments                   |
| `deployment/message-broker`    | Message brokers / queues                                      |
| `cronjob/scheduled-task`       | Scheduled jobs                                               |
| `job/*`                        | One-shot batch jobs                                          |

Always confirm with `occ clustercomponenttype list` + `occ componenttype list -n <ns>` — what's actually installed varies. For each candidate, fetch the schema:

```bash
# Cluster-scoped:
occ clustercomponenttype get deployment/service
# Namespace-scoped:
occ componenttype get database -n <ns>
```

Read `spec.parameters.openAPIV3Schema` and `spec.environmentConfigs.openAPIV3Schema` — they describe what `Component.spec.parameters` and `ReleaseBinding.spec.componentTypeEnvironmentConfigs` accept.

## 6. Choose where the Workload spec lives (source-build only)

Two paths, real tradeoffs. **Surface this choice to the user** rather than defaulting silently.

| | Path A — `workload.yaml` in the source repo | Path B — Workload CR in the GitOps repo |
| --- | --- | --- |
| **Where the spec lives** | Source-controlled, in the source repo | In the GitOps repo, hand-authored |
| **How a change lands** | Edit file → commit → push → rebuild | Edit YAML → commit → push (this skill's PR) |
| **Reviewability** | PR in source repo | PR in GitOps repo |
| **Rebuild behavior** | Full `PUT` of the entire spec from the descriptor — regenerates endpoints / env / deps / files / image. Any edits to non-image fields in the GitOps repo are **overwritten on the next rebuild**. | Only `container.image` is patched by the build; **all other fields persist across rebuilds**, including prior hand-edits. |
| **Iteration speed** | Slower per change (source commit + push + rebuild) | Faster — direct YAML edit + PR + reconcile |
| **Best when** | Workload contract should be versioned with code; promotion is via git; descriptor is the single source of truth | Iterating on the runtime contract before it stabilizes; you want fast platform-side changes without touching the source repo |

> **Migrating from Path B → Path A is one-way and destructive.** The first rebuild that finds a newly-added `workload.yaml` will full-PUT from it, overwriting the GitOps repo's current spec (including any hand-edits). To migrate cleanly: dump the current Workload (`occ workload get <component>-workload -n <ns>`), reconstruct the descriptor from that output, commit to the source repo, then rebuild.

For BYO, there's no `workload.yaml` and no rebuild — the Workload CR in the GitOps repo is the only spec.

## 7. `autoDeploy` decision

`Component.spec.autoDeploy` controls what happens after a new `ComponentRelease` is created (on Component creation, Workload update, or successful build):

- **`autoDeploy: true`** (default if omitted) — OpenChoreo auto-creates a `ReleaseBinding` for the *first* environment in the DeploymentPipeline. Promotion to subsequent environments still requires explicit action.
- **`autoDeploy: false`** — nothing deploys until a `ReleaseBinding` is committed explicitly.

Pick `true` for active development (every push lands in dev). Pick `false` if a human gate is required even for the first environment.

> In strict GitOps, you may prefer `autoDeploy: false` even for dev so every deploy is a reviewable PR. Discuss with the user.

## 8. Where to go next

Once you've decided BYO vs source-build and picked a ComponentType:

- BYO: [`./recipes/onboard-component-byo.md`](./recipes/onboard-component-byo.md)
- Source-build: [`./recipes/onboard-component-source-build.md`](./recipes/onboard-component-source-build.md)
- Multi-component apps with dependencies: also load [`./recipes/connect-components.md`](./recipes/connect-components.md)
- Per-env overrides: [`./recipes/override-per-environment.md`](./recipes/override-per-environment.md)
- After deployment: [`./recipes/promote.md`](./recipes/promote.md), [`./recipes/verify-and-debug.md`](./recipes/verify-and-debug.md)
