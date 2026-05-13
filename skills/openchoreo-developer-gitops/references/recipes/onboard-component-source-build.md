# Recipe — Onboard a Component (source-build)

OpenChoreo builds the image from a Git repo via a PE-authored Workflow. The build pipeline emits a Workload CR, ComponentRelease, and ReleaseBinding via a PR against the GitOps repo. The developer commits the Component (and optionally `workload.yaml` in the source repo) and triggers the build.

For BYO image, see [`onboard-component-byo.md`](./onboard-component-byo.md).

## Preconditions

- This skill's Step 0 checks have passed.
- The Project exists.
- A Workflow that supports source-build is installed and the target `ComponentType.allowedWorkflows[]` includes it. Discover: `occ clusterworkflow list` / `occ workflow list -n <ns>`. The sample-gitops bundle ships:
  - `docker-gitops-release` — for repos with a Dockerfile.
  - `google-cloud-buildpacks-gitops-release` — for repos without a Dockerfile (auto-detects Go / Java / Node / Python / .NET / Ruby / PHP).
  - `react-gitops-release` — for React / SPA apps.
- The build's `gitops-repo-url` in the Workflow CR's `runTemplate.spec.arguments.parameters` points at *this* GitOps repo. Verify with the PE side if you're unsure.
- A `ClusterSecretStore` provides `git-token` (clone source) and `gitops-token` (push branches + open PRs on the GitOps repo). Platform-side concern; verify with the platform team or check `kubectl get clustersecretstore`.

## Steps

`<src>` = source repo URL. `<app-path>` = path inside source repo to the buildable directory (often `/` or `/<service>`).

### 1. (Optional) Author `workload.yaml` in the source repo — Path A

If the source repo is in the workspace, write `workload.yaml` at the **root of the chosen `appPath`** (not the repo root, unless `appPath` is `.`).

Use [`../../assets/workload-descriptor.yaml`](../../assets/workload-descriptor.yaml) as a starting template — it carries the full schema with comments (`endpoints[]`, `configurations.env[] / files[] / secrets`, `dependencies.endpoints[]`), the field-name diff vs the Workload CR, and a worked example. Read it, write the customized version to `<src-repo>/<app-path>/workload.yaml`.

> Field names differ from the Workload CR: `configurations.env[].name` (not `container.env[].key`), `endpoints[]` (list with `name`, not map), `dependencies.endpoints[]` (same name; descriptor uses the same nesting).

Commit and push to the source repo with **explicit user approval** per step. The Workload-descriptor file should land before the Component is created so the first build can read it.

If skipping Path A (Path B), the build will produce a Workload CR that only carries `container.image`. Hand-author endpoints / env / deps directly in the GitOps repo via the Workload CR after the first build — see *Path B* below.

### 2. Scaffold the Component in the GitOps repo

```bash
mkdir -p "namespaces/<ns>/projects/<project>/components/<component>"

occ component scaffold <component> \
  --namespace <ns> --project <project> \
  --clustercomponenttype deployment/service \
  --clusterworkflow docker-gitops-release \
  -o "namespaces/<ns>/projects/<project>/components/<component>/component.yaml"
```

Adjust:

- `--componenttype` / `--workflow` for namespace-scoped variants.
- Add `--clustertraits` / `--traits` for trait attachments.

Open the file. Fill in `spec.workflow.parameters`:

```yaml
spec:
  workflow:
    kind: ClusterWorkflow                          # match what the scaffold flag set
    name: docker-gitops-release
    parameters:
      componentName: <component>
      projectName: <project>
      repository:
        url: <src>
        revision:
          branch: main
          commit: <8-char-or-full-SHA>             # required — resolve via: git ls-remote <src> refs/heads/main | cut -c1-40
        appPath: /<app-path>                       # MUST start with /; the build concatenates "/mnt/vol/source" + appPath without a separator
      docker:
        context: /<app-path>
        filePath: /<app-path>/Dockerfile
      workloadDescriptorPath: workload.yaml         # relative to appPath
  autoBuild: false                                  # default; flip to true for webhook builds
  autoDeploy: true                                  # the build's release auto-binds to dev
  parameters:
    # Per the ComponentType's parameters schema
    port: 8080
```

> **Workaround: `appPath` must start with `/` here, even though the schema says relative.** The Workflow CR schema (`docker-with-gitops-release.yaml`) declares `appPath` as relative (default `"."`), but the build template at `docker-with-gitops-release-template.yaml:236` does a raw concat: `/mnt/vol/source${APP_PATH}/...`. A relative value like `foo/bar` produces `/mnt/vol/sourcefoo/bar/...` (descriptor not found), and the template *silently falls through* to "no descriptor" mode, emitting a Workload with only `container.image`. Build reports `Succeeded`. Until the upstream template normalizes the path, lead `appPath` with `/`. This contradicts the schema — it's a known workaround, not the canonical contract.
>
> **`revision.commit` must be a SHA, not a branch name.** The build's RELEASE_NAME is `<component>-${COMMIT:0:8}`. Passing `commit: main` makes the release file `<component>-main.yaml`, and re-running with the same value collides with the existing release file (the generator errors out on "already exists" before checking content). Resolve a SHA up-front with `git ls-remote <src> refs/heads/<branch>`; re-resolve when re-running.

> The build creates a Workload CR named `<component>-workload` (always; overrides any `metadata.name` from the descriptor). Don't author or commit a Workload CR yourself for source-build Components on Path A.

### 3. Commit the Component (only) on a feature branch, open a PR

Branch `release/<component>-onboard-<ts>`, path `namespaces/<ns>/projects/<project>/components/<component>/component.yaml` only, message `"Component <component>: onboard source-build"`. Canonical flow in [`../authoring.md`](../authoring.md) *Git workflow*.

> Notice no Workload / ComponentRelease / ReleaseBinding in this PR. Those come from the build pipeline's own PR after the first successful run.

Wait for merge. After Flux applies the Component CR, the controller picks it up; if `autoBuild: true` and a webhook is wired, the build triggers automatically on the next source push. Otherwise: trigger manually (step 4).

### 4. Trigger the first build

```bash
occ component workflow run <component> -n <ns> -p <project>
```

Or apply a standalone `WorkflowRun` manifest with `spec.workflow.name: <workflow>` and the matching `spec.workflow.parameters`. **WorkflowRuns are imperative — never commit them to Git.**

Watch:

```bash
occ workflowrun list -n <ns>
occ workflowrun get <run-name> -n <ns>
occ component workflowrun logs <component> -n <ns> -f          # latest run for this component
# Or:
occ workflowrun logs <run-name> -n <ns> -f                     # specific run
```

`occ workflowrun logs` covers both live runs (workflow plane) and completed runs (observer); no need to `kubectl logs -n workflows-<ns> <pod>` by hand.

If the build fails:

- **Exit 125 with `BUILDPLATFORM` error** — the source Dockerfile uses `ARG BUILDPLATFORM` multi-stage syntax. Switch to BYO (see [`onboard-component-byo.md`](./onboard-component-byo.md)) — the buildah-based builder doesn't support this.
- **Clone failure** — `git-token` secret missing or doesn't have read access. PE concern.
- **Push failure** — `gitops-token` missing or doesn't have write access on the GitOps repo. PE concern.
- **Schema validation error** on the generated Workload — the descriptor's shape doesn't match. Inspect the controller logs on the workflow plane.

### 5. Review and merge the build's PR

A successful build opens a PR on the **GitOps repo** containing:

- `workload.yaml` — the generated Workload CR (named `<component>-workload`).
- `releases/<component>-<date>-<n>.yaml` — a ComponentRelease.
- `release-bindings/<component>-development.yaml` — a ReleaseBinding for the root environment.

Review the PR (especially the Workload — confirm endpoints / env / deps are what you expect from the descriptor). Merge.

Flux reconciles → controller deploys → `occ releasebinding get <component>-development -n <ns>` should show `Ready=True` after a few minutes.

> The build emits a binding **only for the root environment**. Don't pre-create bindings for staging / prod here — use [`promote.md`](./promote.md) once the first env is healthy. Pre-binding to higher envs only when the user explicitly asks (e.g. demo / sandbox spam-everywhere flows).

### 6. Verify

Same as BYO step 6 — walk the verification ladder per [`../concepts.md`](../concepts.md).

## Path B — Workload spec authored in GitOps repo (not in source)

Skip step 1. After the first build, the auto-generated Workload CR has only `container.image`. Hand-edit `namespaces/<ns>/projects/<project>/components/<component>/workload.yaml` to add endpoints / env / deps / files. Commit + PR.

Subsequent builds only patch `container.image` — your edits persist. But **adding `workload.yaml` to the source repo later is a one-way migration**: the first rebuild that finds it will full-PUT from it, overwriting all your GitOps-repo edits.

**Persist the Path A vs Path B choice** in `CLAUDE.md` / `AGENTS.md` / agent memory at the repo root, under `## OpenChoreo deploy choices` → `<component>`. Future sessions read this and won't accidentally add a descriptor to a Path B component (which would destructively migrate).

## Iteration loop — committing source changes

For source-build components, the per-iteration loop is:

1. Edit code in the source repo.
2. Commit + push (with user approval per step).
3. **Trigger a build** — either `autoBuild: true` + webhook (no agent action), or `occ component workflow run <component>` manually, or a manual `gh workflow run`-style trigger if the user has external CI in addition.
4. Wait for the build to complete.
5. Review and merge the auto-generated PR on the GitOps repo.
6. Wait for Flux to reconcile.
7. Verify.

For Path A users, code changes that also need a workload-contract update (new endpoint, new dep) require editing `workload.yaml` in the source repo too — both in the same source-repo commit.

## Gotchas

- **`workload.yaml` lives at `<src-repo>/<appPath>/workload.yaml`**, not the source-repo root (unless `appPath` is `.`). Easy to misplace.
- **`appPath` without leading `/` silently breaks the build (workaround).** The schema says relative paths (default `"."`), but the build template raw-concats `/mnt/vol/source` + `appPath` with no separator. Result: descriptor isn't found, build emits a Workload with only `container.image`, build reports `Succeeded`. Until upstream normalizes the path, always lead with `/` even though it contradicts the schema.
- **`revision.commit` must be a SHA.** Release files are named `<component>-${COMMIT:0:8}`; passing a branch name causes filename collisions on re-runs. Resolve via `git ls-remote`.
- **Re-running with the same `revision.commit`** trips the generator's "release file already exists" guard. Either bump the SHA (new commit on the source side) or delete the prior release file before re-running.
- **The Workload CR's `metadata.name` is fixed at `<component>-workload`** — the build overrides whatever the descriptor / scaffold writes. `occ workload get my-svc -n <ns>` returns nothing; use `<component>-workload`.
- **Descriptor and CR field names differ.** See [`../concepts.md`](../concepts.md) *Workload Descriptor*.
- **`Component.spec.workflow.kind` defaults to `ClusterWorkflow`.** Set explicitly to `Workflow` for namespace-scoped workflows.
- **`autoBuild: true` requires a webhook** on the source repo pointing at OpenChoreo's `gitrepositorywebhooks` receiver. Without one, source pushes won't trigger builds. Verify with PE side.
- **Build images push to a registry.** Confirm `registry-url` in the Workflow CR's `runTemplate.spec.arguments.parameters` matches a registry the workflow plane can push to and the data plane can pull from.
- **PR conflicts on the GitOps repo.** Two concurrent builds for the same component produce overlapping PRs on the same release-bindings file. Merge in order or rebase.

## Related

- [`onboard-component-byo.md`](./onboard-component-byo.md) — alternative path: pre-built image
- [`update-workload.md`](./update-workload.md) — modify an existing Workload (descriptor edit + rebuild, or direct GitOps edit)
- [`promote.md`](./promote.md) — promote releases the build produces
