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

```yaml
# <src-repo>/<app-path>/workload.yaml
apiVersion: openchoreo.dev/v1alpha1
kind: Workload                                     # ignored; build sets to <component>-workload
metadata:
  name: <component>                                # overridden by build
spec:
  owner:
    componentName: <component>
    projectName: <project>
  endpoints:
    - name: http
      type: HTTP
      port: 8080
      visibility: [external]
  configurations:                                  # descriptor form
    env:
      - name: LOG_LEVEL
        value: info
    files:
      - name: /etc/config/app.json
        mountPath: /etc/config/app.json
        value: |
          {"feature_x": false}
  dependencies:
    endpoints:
      - component: postgres
        name: tcp
        visibility: project
        envBindings:
          host: DB_HOST
          port: DB_PORT
```

> Field names differ from the Workload CR: `configurations.env[].name` (not `container.env[].key`), `endpoints[].name` (list, not map), `dependencies.endpoints[]` (same name; descriptor uses the same nesting).

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
        appPath: <app-path>
      docker:
        context: <app-path>
        filePath: <app-path>/Dockerfile
      workloadDescriptorPath: workload.yaml         # relative to appPath
  autoBuild: false                                  # default; flip to true for webhook builds
  autoDeploy: true                                  # the build's release auto-binds to dev
  parameters:
    # Per the ComponentType's parameters schema
    port: 8080
```

> The build creates a Workload CR named `<component>-workload` (always; overrides any `metadata.name` from the descriptor). Don't author or commit a Workload CR yourself for source-build Components on Path A.

### 3. Commit the Component (only)

```bash
git checkout -b release/<component>-onboard-$(date +%Y%m%d-%H%M%S)
git add "namespaces/<ns>/projects/<project>/components/<component>/component.yaml"
git status                                           # show before committing
git commit -s -m "Component <component>: onboard source-build"
git push origin HEAD                                 # only after user confirmation
gh pr create --fill                                  # only after user confirmation
```

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
occ component workflow logs <component> -n <ns> -f
```

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
- **The Workload CR's `metadata.name` is fixed at `<component>-workload`** — the build overrides whatever the descriptor / scaffold writes. `occ workload get my-svc -n <ns>` returns nothing; use `<component>-workload`.
- **Descriptor and CR field names differ.** See [`../concepts.md`](../concepts.md) *Workload Descriptor*.
- **`Component.spec.workflow.kind` defaults to `ClusterWorkflow`.** Set explicitly to `Workflow` for namespace-scoped workflows.
- **`autoBuild: true` requires a webhook** on the source repo pointing at OpenChoreo's `gitrepositorywebhooks` receiver. Without one, source pushes won't trigger builds. Verify with PE side.
- **Build images push to a registry.** If the registry is hardcoded to `host.k3d.internal:10082` (k3d-local), it won't work on cloud clusters. Confirm `registry-url` in the Workflow CR's `runTemplate.spec.arguments.parameters`.
- **PR conflicts on the GitOps repo.** Two concurrent builds for the same component produce overlapping PRs on the same release-bindings file. Merge in order or rebase.

## Related

- [`onboard-component-byo.md`](./onboard-component-byo.md) — alternative path: pre-built image
- [`update-workload.md`](./update-workload.md) — modify an existing Workload (descriptor edit + rebuild, or direct GitOps edit)
- [`promote.md`](./promote.md) — promote releases the build produces
