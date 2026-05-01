# Getting started

**Load this when deploying an app or project to OpenChoreo for the first time** — no Project yet, or first time the user has touched this cluster. It walks you through the orientation (what's already provisioned, BYO vs source-build, which ComponentType, repo conventions, `autoDeploy` choice) and routes you into the right recipe for the actual create steps.

**Skip this when working with existing Components** — if you're changing an image, updating parameters, rebuilding from source, modifying a workload, promoting, or troubleshooting, go directly to the matching recipe in `./recipes/`. The recipes cover both first-time and ongoing flows; this file is the orientation that wraps the first deploy.

Pair this with `./concepts.md` (concepts always; getting-started only on a first-time deploy).

## 0. Is the agent inside the source repo?

Before pre-flight, check whether the agent is operating inside the git repo for the thing being deployed. This unlocks tighter coordination than just authoring resources.

Heuristics:

- `pwd` is inside a git repo (look for `.git`).
- The user's request points at code in this directory ("deploy this app", "deploy my service", "push my changes to OpenChoreo") rather than an external image URL or a third-party demo.

**If yes:** the agent can write `workload.yaml`, stage / commit / push, open PRs (`gh pr create`), and trigger source-build CI or external CI on behalf of the user — see *When you're in the source repo* in [`./recipes/build-from-source.md`](./recipes/build-from-source.md) (for source-build) or [`./recipes/deploy-prebuilt-image.md`](./recipes/deploy-prebuilt-image.md) (for BYO + external CI). **Always coordinate with the user before any git action.**

**If no** (third-party demo, external prebuilt image, repo the user doesn't control): skip the in-repo affordances. Proceed with the rest of this checklist normally — author resources via MCP, point `image:` at the external registry, no git involvement from the agent.

## Up-front questions

For first-time deploys, ask the user a few decisions *before* authoring resources. One round of clarifying questions beats discovering misalignment after the first failed deploy.

> **Ask interactively, not as a wall of text.** These are choice questions — use whatever interactive question-asking affordance your agent provides (in Claude Code that's the `AskUserQuestion` tool with explicit options) rather than dumping all questions in a single text block with defaults. One question (or a small batch of related ones) at a time, with the inferred default pre-selected, is much easier for the user than a long-form decision form.
>
> **Order is flexible — but most questions are sharper after the pre-flight discovery (§1 below).** Once you know which CI workflows, ComponentTypes, and Environments the cluster actually has, you can ask "which of these workflows fits your build?" instead of an open-ended "which CI workflow?" Two cheap questions you can ask up front before pre-flight (since they don't depend on cluster state): BYO vs source-build, and how the BYO image is built (external CI / manual). The rest fit naturally after §1.

- **BYO image or source-build?** If we're in the source repo, default to source-build. If the user has a published image or this is a third-party app, default to BYO.
- **If source-build:** which CI Workflow? List with `list_cluster_workflows` / `list_workflows`. The right one depends on the repo's build system — Dockerfile present → `dockerfile-builder`; clean source → a buildpacks variant (`gcp-buildpacks-builder`, `paketo-buildpacks-builder`, etc.).
- **If BYO image, how does the image get built?** Three cases:
  - **External CI** (GitHub Actions, GitLab CI, Jenkins, Buildkite, …) — ask which trigger to use (push to a branch, `gh workflow run`, manual `workflow_dispatch`) and what registry / tag scheme the CI publishes.
  - **Manual** (user runs `docker build` / `docker push` themselves) — confirm the registry, repo, and tag style (`v1.2.3`, commit SHA, `latest`). The agent will not run `docker push` without explicit per-iteration approval.
  - **Hybrid / unsure** — treat as manual until confirmed; never assume a pipeline you haven't seen.
- **Deploy scope:** first environment only, or auto-promote along the DeploymentPipeline?
- **`autoDeploy`:** every push lands in dev (`true`), or human gate even for the first env (`false`)?

### Persist the answers

Once decided, **don't make the user re-answer next session.** Save the choices to `CLAUDE.md` (or `AGENTS.md`) at the repo root under a clear heading — e.g. `## OpenChoreo deploy choices`. Future sessions read this and skip the questions. If `CLAUDE.md` already has these decisions recorded, read them first and only ask about gaps.

Useful things to capture: component name, project, ComponentType chosen, BYO vs source-build, CI workflow name, external-CI trigger command (for BYO), `autoDeploy` choice, target environments.

## 1. Pre-flight discovery — what does the namespace already provide?

OpenChoreo separates platform setup from app deployment. Before authoring any Component, confirm what the platform team has provisioned in the target namespace.

Run these MCP discovery calls:

- `list_namespaces` — pick the target. Default is `default` unless the team uses a dedicated namespace.
- `list_environments(namespace)` — at least one Environment must exist (typically `development`). If none, deployment is impossible until the platform team creates one.
- `list_deployment_pipelines(namespace)` — defines the promotion order across Environments. Without one, deploys still work for the first env but there's no promotion path.
- `list_cluster_component_types` **and** `list_component_types(namespace)` — the available application templates. The platform may register cluster-scoped (`ClusterComponentType`) or namespace-scoped (`ComponentType`) — check **both** lists; either is a valid pick. If both are empty, `create_component` will fail. See *Pick a ComponentType* below.
- `list_cluster_workflows` **and** `list_workflows(namespace)` — the available CI Workflows (`dockerfile-builder`, `gcp-buildpacks-builder`, `paketo-buildpacks-builder`, `ballerina-buildpack-builder` are typical cluster-scoped ones). Same dual-scope check applies. Relevant only for source-build.
- `list_cluster_traits` **and** `list_traits(namespace)` — the available cross-cutting capabilities (alerts, ingress, storage, OAuth2 proxy, etc.). Same dual-scope check. Skim before assuming a feature has to live in your app code.
- `list_dataplanes(namespace)` — at least one DataPlane must exist for any Environment to actually deploy. Read-only check.

If any required pre-req is missing, hand off per the SKILL.md's *What this skill cannot do* rule.

## 2. Code discovery — infer the workload contract

If we're inside the source repo (per §0), walk the code to figure out what the workload actually needs at runtime. The output of this step feeds either the `workload.yaml` descriptor (source-build, committed to the repo) or the Workload spec passed to `create_workload` / `update_workload` (BYO, or source-build enrichment after the first build). Don't author yet — just collect facts.

Read for:

- **Endpoints — what ports does the app listen on, and on what protocol?**
  - Server bind code: `app.listen(8080)`, `http.ListenAndServe(":3000", ...)`, `uvicorn ... --port 8080`, `server.bind(...)`, framework defaults.
  - `EXPOSE` directive(s) in the Dockerfile.
  - Default port in framework config (Spring Boot `application.yml`, ASP.NET `appsettings.json`, etc.).
  - Protocol per endpoint: HTTP (REST/JSON), gRPC (`.proto` files, gRPC server libs), GraphQL (`schema.graphql`, GraphQL server libs), Websocket (`ws://`, `WebSocket(...)` upgrades), raw TCP/UDP.
- **Dependencies — what other services does this app talk to?**
  - HTTP / gRPC clients in source: client libraries, base URL constants, env-driven addresses (`process.env.USER_SERVICE_URL`, `os.Getenv("PAYMENTS_HOST")`).
  - Database / cache / broker clients: `redis://`, `postgres://`, `nats://`, `mongodb://`, `mysql://` connection strings.
  - SDK clients pointing at internal hostnames or sibling components.
- **Required env vars — variables the app reads at startup.**
  - `process.env.X`, `os.Getenv("X")`, `os.environ["X"]`, `System.getenv("X")`.
  - Config schemas (Pydantic settings, Viper, dotenv, framework `application.properties`, etc.).
- **Config files / mounted assets — files the app reads from disk at runtime.**
  - `fs.readFileSync('/etc/...')`, hard-coded mount paths, runtime `config.json` reads (common in SPAs).

For repos with multiple services, do this per-service. If a service has no inbound endpoints (worker / cron job), an empty `endpoints` list is fine.

## 3. Confirm the workload contract with the user

Before authoring `workload.yaml` or calling `create_workload`, present what §2 inferred and **ask the user to confirm or correct**. Catching a wrong dependency or missed env var here is far cheaper than after the first failed deploy.

Show a tabular summary, one block per service:

```text
Service: <component-name>
  Endpoints:
    - <name> (<type>, port <port>) — visibility: <project|namespace|internal|external>
  Dependencies:
    - <target-component>.<endpoint>  →  injected as $<ENV_VAR_NAME>
        (evidence: <file:line where the agent inferred this>)
  Required env vars:
    - <name> = <literal | "from SecretReference X" | "from dependency injection">
  Config files mounted:
    - <mountPath> = <source: inline | from SecretReference | from descriptor file>
```

Then ask, explicitly. **Use an interactive question affordance** — in Claude Code that's the `AskUserQuestion` tool with concrete options (e.g. yes / no / let-me-edit-this); ask one focused question at a time rather than dumping the whole list as prose with defaults at the bottom. The inferred mapping should be the pre-selected default; the user clicks through the ones they're happy with and only stops on the ones that need editing.

- **Is the dependency mapping complete?** Inferred maps often miss feature-flagged or optionally-enabled clients, plus dependencies that resolve through service-mesh DNS rather than env vars.
- **Are the dependency *target* component names right?** A client variable named `userService` in source might map to a Component named `user-svc` on the cluster. The user knows; you have to ask.
- **Visibility levels OK?** Public-facing frontends need `external`; service-to-service deps default to `project`.
- **Which env vars should come from a `SecretReference` vs a literal?** API keys, tokens, DB passwords → SecretReference. PORT, feature flags → literals.
- **Anything missing?** Always end the confirmation with this — humans always know something the code doesn't say.

The confirmed contract is what gets encoded in §6.

## 4. Pick a deployment shape

Two top-level paths:

### BYO image (prebuilt container image)

You provide an OCI image; OpenChoreo runs it. No build step.

- Resources you create: `Component` (no `spec.workflow`) **plus** `Workload`.
- Recipe: `./recipes/deploy-prebuilt-image.md`.
- Best for: third-party / public apps with published images, monorepos where CI lives elsewhere, ad-hoc images.

### Source-build (OpenChoreo builds from a Git repo)

You give OpenChoreo a Git repo + builder choice; the platform builds the image and auto-generates the Workload.

- Resources you create: `Component` with `spec.workflow` referencing a `ClusterWorkflow`. The build creates `{component}-workload`; do **not** call `create_workload`.
- Recipe: `./recipes/build-from-source.md`.
- Best for: first-party code where you want OpenChoreo's build pipeline to manage image lifecycle.

> **Third-party / public apps: default to BYO.** Source builds commonly fail on third-party Dockerfiles because they use `ARG BUILDPLATFORM` multi-stage syntax that OpenChoreo's buildah builder does not support. If you see exit code 125 with a `BUILDPLATFORM` error, switch to BYO immediately.

## 5. Pick a ComponentType

The `componentType` reference (format: `{workloadType}/{name}`) determines what Kubernetes resources the platform generates. Common shapes the default platform setup ships:

| ComponentType | Use for |
|---|---|
| `deployment/service` | Backend HTTP / gRPC / TCP services |
| `deployment/web-application` | Public-facing frontends (SPAs, server-rendered web apps) |
| `deployment/worker` | Background workers, queue consumers, load generators |
| `statefulset/datastore` | Stateful stores (databases, message brokers) |
| `cronjob/*` | Scheduled jobs |
| `job/*` | One-shot batch jobs |

If the namespace has its own namespace-scoped ComponentTypes, `list_component_types` shows them. Always confirm the available list with `list_cluster_component_types` (and `list_component_types`) before assuming a name exists.

For each candidate, fetch the schema (`get_cluster_component_type_schema <name>`) before authoring — it tells you which `parameters` the type accepts and what their constraints are.

## 6. Configure the workload (apply the confirmed contract)

The contract from §3 has to land somewhere. Always **fetch the schema first** — `get_workload_schema` (no arguments) returns the spec shape, including which fields are required and the `dependencies.endpoints[]` structure. Don't compose specs from memory.

For BYO image, the workload is created/updated via MCP (Path B below); there's only one path because there's no build pipeline involved.

For source-build, two paths exist, with real tradeoffs. **Surface the choice to the user** rather than defaulting silently. The build's `generate-workload` step behaves differently per path — neither is the universal default.

| | Path A — `workload.yaml` in the repo | Path B — `update_workload` via MCP |
|---|---|---|
| **Where the spec lives** | source-controlled, in the repo | cluster only |
| **How a change lands** | edit file → commit → push → rebuild | one MCP call against `{component}-workload` |
| **Reviewability** | PR review of workload changes | platform-side change, no review trail |
| **Rebuild behavior** | full `PUT` of the entire spec from the descriptor — regenerates endpoints / env / deps / files / image. MCP edits to non-image fields are overwritten. | only `container.image` is patched; **all other fields persist across rebuilds**, including prior MCP edits |
| **Iteration speed** | slower per change (commit + push + rebuild) | fast — single MCP call, no rebuild needed |
| **Best when** | the contract should be versioned with code; promotion is via git; descriptor is the single source of truth | iterating on the runtime contract before it stabilizes; you want fast platform-side changes without touching git |

> **Migrating from Path B → Path A is one-way and destructive.** The first rebuild that finds a newly-added `workload.yaml` will full-PUT from it, replacing the cluster's current spec (including any MCP-applied endpoints / deps / env). To migrate cleanly: `get_workload` → build the descriptor from that output → commit → rebuild.

### Path A — `workload.yaml` in the source repo

1. Use [`../assets/workload-descriptor.yaml`](../assets/workload-descriptor.yaml) as a starting template.
2. Encode the confirmed contract: `endpoints[]`, `dependencies.endpoints[]`, `configurations.env[]`, `configurations.files[]`. Schema reference for the descriptor is in the asset's comments.
3. Place the file at the **root of the chosen `appPath`** (not the repo root, unless `appPath` is `.`). Build-time read.
4. Commit and push (with explicit user approval per step — see [`./recipes/build-from-source.md`](./recipes/build-from-source.md) → *When you're in the source repo*).

Build flow:

```text
Git repo → ClusterWorkflow (build steps) → image push → workload.yaml → {component}-workload CR
```

`Dockerfile` placement: at the path your builder expects (usually repo root; override via `docker.context` / `docker.filePath`). Both fields are **repo-root-relative even when `appPath` is set**.

> **Descriptor / CR field-name diff**: the build's `generate-workload-cr` step transforms the descriptor into the CR. Field names differ slightly:
>
> | Field | Workload CR | `workload.yaml` descriptor |
> |---|---|---|
> | Env vars | `container.env[].key` | `configurations.env[].name` |
> | File mounts | `container.files[].key` | `configurations.files[].name` |
> | Endpoints | `endpoints` (map keyed by name) | `endpoints[]` (list with `name`) |
>
> When copy-pasting between recipes, check which format the example is in.
>
> **The auto-generated workload is always `{component}-workload`** — the build overrides any `metadata.name` from the descriptor. So `get_workload my-svc` returns nothing; use `get_workload my-svc-workload`.

### Path B — MCP-driven Workload spec

The workload spec lives only on the cluster. Used for BYO images by default; available for source-build too if the user prefers MCP edits over a committed descriptor.

1. `get_workload_schema` to discover the spec shape.
2. Compose the Workload spec encoding the confirmed contract: `container.image`, `container.env[]`, `container.files[]`, `endpoints` (map), `dependencies.endpoints[]`. Use `container.env[].key` and `container.files[].key` (CR shape, not descriptor shape).
3. **First-deploy:** `create_workload(namespace_name, component_name, workload_spec)`. (BYO components only — never `create_workload` for source-build, since the build auto-generates `{component}-workload`.)
4. **Updating:** `update_workload(namespace_name, workload_name, workload_spec)`. **Full-spec replacement, not a partial patch** — read current state with `get_workload` first, modify locally, write the complete spec back. Omitting a field deletes it.

For source-build using Path B: as long as no `workload.yaml` is committed in the repo, MCP edits are durable across rebuilds — the build only updates `container.image`. If a `workload.yaml` later appears in the repo, the next rebuild will full-PUT from it, replacing prior MCP edits. Note in `CLAUDE.md` that this component is on Path B so the next session knows not to add a descriptor casually (it's a one-way migration that would clobber the live spec).

## 7. `autoDeploy` decision

`Component.spec.autoDeploy` controls what happens after a new `ComponentRelease` is created (on Component creation, Workload update, or successful build):

- **`autoDeploy: true`** (default if omitted) — OpenChoreo auto-creates a `ReleaseBinding` for the *first* environment in the DeploymentPipeline. Promotion to subsequent environments still requires explicit action.
- **`autoDeploy: false`** — nothing deploys until you explicitly call `create_release_binding`.

Pick `true` for active development (every push lands in dev). Pick `false` if a human gate is required even for the first environment.

## 8. Where to go next

Once you've decided BYO vs source-build and picked a ComponentType, route to the matching recipe:

- BYO image: `./recipes/deploy-prebuilt-image.md`
- Source-build: `./recipes/build-from-source.md`
- Multi-component apps with dependencies: also load `./recipes/connect-components.md`
- Secrets / env vars / files / per-env overrides: `./recipes/manage-secrets.md`, `./recipes/configure-workload.md`, `./recipes/override-per-environment.md`
- After deployment: `./recipes/deploy-and-promote.md` (promote across envs), `./recipes/inspect-and-debug.md` (verify / troubleshoot)
