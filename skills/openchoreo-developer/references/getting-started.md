# Getting started

Load when deploying an app or project to OpenChoreo for the first time. Pair with `./concepts.md`.

Skip when working with existing Components — go directly to the matching recipe.

## 1. Inside the source repo?

Quick check, drives the rest:

- `pwd` is inside a git repo.
- The user's request points at code in this directory ("deploy this app", "push my changes to OpenChoreo") rather than an external image URL.

**If yes**, the agent can write `workload.yaml`, stage / commit / push, open PRs, and trigger source-build runs. Coordinate with the user before any git action.

**If no**, skip in-repo affordances; author via MCP, point `image:` at the external registry, no git.

## 2. Code discovery

Walk the code first; questions come after (§3). For each candidate service, infer:

- **Project + component layout.** One service → one Component. A multi-service repo may need multiple Components, often grouped under one Project.
- **Endpoints — port + protocol.** Server bind code (`app.listen`, `http.ListenAndServe`, `uvicorn --port`), Dockerfile `EXPOSE`, framework defaults. Protocol per endpoint: HTTP/REST, GraphQL, gRPC, WebSocket, TCP, UDP.
  > **Gateway gotcha.** External (public) ingress uses the northbound gateway — usually configured. `namespace` / `internal` visibility uses the westbound gateway, which may not be. WebSocket endpoints also depend on whichever gateway routes them supporting upgrades. If the visibility you want isn't `external` or `project`, verify the gateway exists with PE before authoring.
- **Dependencies.** HTTP / gRPC clients to other services, DB / cache / broker connection strings.
- **Env vars.** `process.env.X`, `os.Getenv("X")`, framework config schemas (Pydantic settings, Viper, Spring `application.yml`, …).
- **Secrets + mounted files.** API keys / DB credentials (→ `SecretReference`), runtime config files (`fs.readFileSync('/etc/...')`, common in SPAs).

For repos with multiple services, do this per-service. A worker / cron job with no inbound traffic → empty endpoints is fine.

## 3. Confirm the discovery + answer the questions

Show what §2 inferred as a tabular summary per service:

```text
Service: <component-name>
  Endpoints:
    - <name> (<type>, port <port>) — visibility: <project|namespace|internal|external>
  Dependencies:
    - <target-component>.<endpoint>  →  injected as $<ENV_VAR_NAME>  (evidence: <file:line>)
  Env vars:
    - <name> = <literal | "from SecretReference X" | "from dependency injection">
  Config files:
    - <mountPath> = <inline | from SecretReference | from descriptor file>
```

Use `AskUserQuestion` per question, defaults pre-selected:

- **BYO image or source-build?** Ask only if §1 says we're inside the source repo. *Source-build* means OpenChoreo's workflow plane builds from this repo; *BYO* means an image is already published elsewhere.
- **If source-build**: which Workflow? `list_cluster_workflows` / `list_workflows`. Pick by build system — Dockerfile → `dockerfile-builder`, no Dockerfile → a buildpacks variant. If nothing fits, confirm with the user before falling back to BYO.
- **If BYO**: how is the image built? External CI / manual / hybrid (assume manual until clarified).
- **`workload.yaml` committed in the source repo?** Source-build only. Yes → descriptor is the source of truth (Path A). No → spec lives on the cluster (Path B). Mixing paths is a one-way trap; pick once. See [§7](#7-configure-the-workload-path-a-or-path-b).
- **Deploy scope**: first environment only, or promote along the pipeline?
- **`autoDeploy`**: `true` = each new release auto-binds to the first env; `false` = explicit binding required even for dev.

**Persist** under `## OpenChoreo deploy choices` in `CLAUDE.md` / `AGENTS.md` / agent memory. Future sessions read this and skip the questions.

## 4. Confirm the final workload contract

Restate the contract with the §3 choices applied — image source, endpoints, dependencies, env, files, secrets. One last "anything missing?" before authoring. Humans always know something the code doesn't say.

## 5. Platform discovery (only what's needed)

Authoring needs the right templates. Discover:

- `list_cluster_component_types` + `list_component_types -n <ns>` — pick the ComponentType.
- `list_cluster_traits` + `list_traits -n <ns>` — any traits to attach.
- `list_cluster_workflows` + `list_workflows -n <ns>` — source-build only.

For each candidate, fetch the schema (`get_cluster_component_type_schema` / `get_cluster_trait_schema` / `get_cluster_workflow_schema`) before composing the spec.

> Environments, DeploymentPipelines, DataPlanes — assume they exist. Inspect them only when troubleshooting a stuck deploy.

## 6. Pick a ComponentType

Shipped defaults (verify with `list_cluster_component_types`):

| ComponentType                | Use for                                                       |
| ---------------------------- | ------------------------------------------------------------- |
| `deployment/service`         | Long-running with one or more endpoints (HTTP / gRPC / TCP)   |
| `deployment/web-application` | SPA / static-served frontend                                  |
| `deployment/worker`          | Long-running, no endpoints                                    |
| `cronjob/scheduled-task`     | Cron-style periodic job                                       |

Namespace-scoped `ComponentType`s (via `list_component_types -n <ns>`) may extend or override these per tenancy.

## 7. Configure the workload (Path A or Path B)

For BYO, only Path B applies (no rebuild pipeline). For source-build, **surface the choice to the user** rather than defaulting silently.

| | Path A — `workload.yaml` in the repo | Path B — `update_workload` via MCP |
|---|---|---|
| **Where the spec lives** | source-controlled, in the repo | cluster only |
| **How a change lands** | edit file → commit → push → rebuild | one MCP call against `{component}-workload` |
| **Reviewability** | PR review of workload changes | no review trail |
| **Rebuild behavior** | full `PUT` of the entire spec from the descriptor — regenerates endpoints / env / deps / files / image. MCP edits to non-image fields are overwritten. | only `container.image` is patched; **all other fields persist across rebuilds**, including prior MCP edits |
| **Iteration speed** | slower per change | fast — single MCP call |
| **Best when** | the contract should be versioned with code | iterating before the contract stabilizes |

> **Migrating Path B → Path A is one-way and destructive.** The first rebuild that finds a newly-added `workload.yaml` will full-PUT from it, replacing the cluster's current spec (including any MCP-applied endpoints / deps / env). Migrate cleanly: `get_workload` → build the descriptor from that → commit → rebuild.

### Path A — `workload.yaml` in the source repo

1. Use [`../assets/workload-descriptor.yaml`](../assets/workload-descriptor.yaml) as a starting template.
2. Encode the §4 contract: `endpoints[]`, `dependencies.endpoints[]`, `configurations.env[]`, `configurations.files[]`. Schema in the asset's comments.
3. Place at the **root of the chosen `appPath`** (not the repo root, unless `appPath` is `.`). Build-time read.
4. Commit and push (user approval per step — see [`./recipes/build-from-source.md`](./recipes/build-from-source.md) *When you're in the source repo*).

> **Descriptor / CR field-name diff** — the build's `generate-workload-cr` step transforms the descriptor into the CR. Slight name differences:
>
> | Field | Workload CR | `workload.yaml` descriptor |
> |---|---|---|
> | Env vars | `container.env[].key` | `configurations.env[].name` |
> | File mounts | `container.files[].key` | `configurations.files[].name` |
> | Endpoints | `endpoints` (map keyed by name) | `endpoints[]` (list with `name`) |
>
> Auto-generated workload is always named `{component}-workload` — the build overrides any `metadata.name` from the descriptor. `get_workload my-svc` returns nothing; use `get_workload my-svc-workload`.

### Path B — MCP-driven Workload spec

The workload spec lives only on the cluster. Used for BYO; available for source-build when MCP edits are preferred over a committed descriptor.

1. `get_workload_schema` to discover the spec shape.
2. Compose the spec encoding the §4 contract: `container.image`, `container.env[]`, `container.files[]`, `endpoints` (map), `dependencies.endpoints[]`. Use the CR shape (`key`), not the descriptor shape (`name`).
3. **First-deploy**: `create_workload(namespace_name, component_name, workload_spec)`. (BYO only — never `create_workload` for source-build; the build auto-generates `{component}-workload`.)
4. **Updating**: `update_workload(namespace_name, workload_name, workload_spec)`. **Full-spec replacement.** Read current state with `get_workload` first, modify locally, write the complete spec back. Omitting a field deletes it.

For source-build on Path B: as long as no `workload.yaml` is committed, MCP edits persist across rebuilds — the build only updates `container.image`. Note in `CLAUDE.md` that this component is on Path B so the next session doesn't add a descriptor casually.

## 8. Where to go next

- BYO image: [`./recipes/deploy-prebuilt-image.md`](./recipes/deploy-prebuilt-image.md)
- Source-build: [`./recipes/build-from-source.md`](./recipes/build-from-source.md)
- Multi-component apps with dependencies: also load [`./recipes/connect-components.md`](./recipes/connect-components.md)
- Secrets / env vars / files / per-env overrides: [`./recipes/manage-secrets.md`](./recipes/manage-secrets.md), [`./recipes/configure-workload.md`](./recipes/configure-workload.md), [`./recipes/override-per-environment.md`](./recipes/override-per-environment.md)
- After deployment: [`./recipes/deploy-and-promote.md`](./recipes/deploy-and-promote.md), [`./recipes/inspect-and-debug.md`](./recipes/inspect-and-debug.md)
