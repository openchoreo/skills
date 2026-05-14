# Deploy a pre-built image (BYOI)

Deploy an existing container image — built elsewhere or pulled from a public registry — as a Component on OpenChoreo. No source build, no workflow.

## Prerequisites

1. The control-plane MCP server is configured and reachable (`list_namespaces` returns).
2. A Project exists. The `default` project is created during install — confirm with `list_projects` (`namespace_name: default`). If you need a new one, see [Variant: create a Project](#variant-create-a-project) below.
3. A ComponentType matching the workload shape exists. The platform may register either cluster-scoped (`ClusterComponentType`) or namespace-scoped (`ComponentType`) — **discover both** by calling `list_component_types` twice, once with `scope: "cluster"` and once with `scope: "namespace"` (+ `namespace_name`). Common cluster-scoped ones in default platform setups: `deployment/service`, `deployment/web-application`, `deployment/worker`, `cronjob/scheduled-task`. Pass the `{workloadType}/{name}` to `create_component`'s `component_type` — the server resolves the kind (namespace-scoped first, cluster-scoped fallback).

## Recipe

### 1. Create the Component

```yaml
create_component
  namespace_name: default
  project_name: default
  name: greeter
  component_type: deployment/service        # one string, "{workloadType}/{name}"
  auto_deploy: true                          # creates ReleaseBinding for first env
```

**Do not pass `workflow`** — that turns this into a source build.

### 2. Inspect the Workload schema

If you're not sure of the workload spec shape, fetch the schema first:

```text
get_workload_schema
  (no parameters)
```

Returns the JSON schema for `workload_spec`, including `container`, `endpoints`, `dependencies`, and validation rules.

### 3. Create the Workload

```yaml
create_workload
  namespace_name: default
  component_name: greeter
  workload_spec:
    owner:
      projectName: default
      componentName: greeter
    container:
      image: ghcr.io/openchoreo/samples/greeter-service:latest
      env:
        - key: LOG_LEVEL
          value: info
    endpoints:
      http:
        type: HTTP
        port: 9090
        visibility: [external]
```

For env vars, file mounts, and endpoint shapes beyond the basics, see `recipes/configure-workload.md`.

### 4. Verify

```yaml
get_component
  namespace_name: default
  component_name: greeter
```

```yaml
list_release_bindings
  namespace_name: default
  component_name: greeter
```

```yaml
get_release_binding
  namespace_name: default
  binding_name: <name from list above>
```

The deployed URL is in `status.endpoints` of the ReleaseBinding — read it from there, do not construct it by hand.

For runtime logs, status conditions, pod events, and crashloop debugging, see [`./inspect-and-debug.md`](./inspect-and-debug.md).

## Variant: create a Project

When the existing `default` project doesn't fit (separate pipeline, ownership boundary):

```yaml
create_project
  namespace_name: default
  name: online-store
  description: "E-commerce application components"
  deployment_pipeline: default              # optional, defaults to "default"
```

Then change `project_name` on your Component and Workload calls to the new project name.

## When you're in the source repo

If the agent is operating inside the git repo whose code becomes the deployed image, the per-iteration loop depends on **how the image gets built**. Ask the user once and persist the answer in `CLAUDE.md`:

- **External CI** (GitHub Actions, GitLab CI, Jenkins, Buildkite, CircleCI, …) builds and publishes on a trigger.
- **Manual** — the user runs `docker build` / `docker push` themselves on their workstation, or has an out-of-band script. No CI in the repo.
- **Hybrid / unsure** — treat as manual until clarified; never assume a CI pipeline you haven't seen.

### External CI

1. **Detect the CI setup** once: check for `.github/workflows/*.yml`, `.gitlab-ci.yml`, `Jenkinsfile`, `.circleci/config.yml`. Skim enough to know what triggers a build (push to a specific branch, `gh workflow run <name>`, manual `workflow_dispatch`) and what registry / image tag the CI publishes to.
2. **Confirm with the user**: which trigger to use, where the image lands, the tag scheme (commit SHA, semver, `latest`). Persist in `CLAUDE.md`.
3. **Per iteration**:
   - Stage / commit / push the code change with explicit user approval per step. For PR-based flows, open the PR via `gh pr create` and wait for the user to merge — don't auto-merge.
   - Trigger CI per the agreed mechanism (a push to the watched branch usually does it; otherwise `gh workflow run`).
   - Wait for the new image to land in the registry (`gh run watch`, or ask the user to confirm).
   - `update_workload` with the new `container.image` tag. Generates a new ComponentRelease; with `autoDeploy: true`, the first env redeploys.

### Manual build & push

The user is the build system. The agent's job is to make the image-tag bump painless once the user has pushed.

1. **Confirm the image reference scheme with the user**: registry, repo, tag style (`v1.2.3`, commit SHA, `latest`). Persist in `CLAUDE.md`.
2. **Per iteration**:
   - Code change happens (user edits, or agent edits with approval).
   - User runs their build/push out of band: typically `docker build -t <registry>/<repo>:<tag> .` then `docker push <registry>/<repo>:<tag>`. The agent can offer the exact command, but **does not run docker push without explicit user approval** — pushes to a registry are visible side-effects.
   - Once the user confirms the new tag is published, `update_workload` with `container.image: <registry>/<repo>:<new-tag>`. ComponentRelease + redeploy follow as usual.

For the manual flow, **don't push code to the remote** unless the user wants you to — there's no CI listening, so the only purpose of pushing source code is the user's own version control hygiene. Ask before doing it.

In all cases the Component itself doesn't change between iterations — only the Workload's `container.image` reference. Keep the loop tight: one user-approved action per iteration.

## Gotchas

- **`component_type` is a single string in `{workloadType}/{name}` form**, not a separate kind+name pair. The server auto-resolves the kind: it looks up a namespace-scoped `ComponentType` with that name first and falls back to `ClusterComponentType`. So one `{workloadType}/{name}` works whether the type was discovered via `list_component_types` with `scope: "namespace"` or `scope: "cluster"` — name collisions across scopes resolve to the namespace-scoped one.
- **For BYOI, do not pass `workflow` to `create_component`.** Adding a workflow turns this into a source build and triggers failed builds.
- **For BYOI, you create the Workload yourself** via `create_workload`. Source-build components auto-generate `{component}-workload`; never call `create_workload` for those. BYOI is the opposite.
- **Workload `owner` (projectName + componentName) is immutable** after creation. Pick names carefully.
- **`env` and `files` entries need exactly one of `value` or `valueFrom`** — not both, not neither. Validation fails otherwise.
- **`auto_deploy: true` only deploys to the first environment** in the pipeline. Promotion to staging/prod uses `create_release_binding` for each subsequent environment — see `recipes/deploy-and-promote.md`.
- **Trust ReleaseBinding status for the deployed URL.** Don't construct hostnames from the Component name and an environment guess — gateway routes vary by deployment topology.

## Related recipes

- [`configure-workload.md`](configure-workload.md) — env vars, config files, endpoint visibility, traits
- [`connect-components.md`](connect-components.md) — declare endpoint dependencies on other components
- [`manage-secrets.md`](manage-secrets.md) — SecretReference + secret-referenced env vars
- [`deploy-and-promote.md`](deploy-and-promote.md) — promote to next environment, rollback
- [`inspect-and-debug.md`](inspect-and-debug.md) — logs, status, k8s artifacts
- [`build-from-source.md`](build-from-source.md) — alternative path: build the image from a Git repo
