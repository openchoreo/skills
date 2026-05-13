# Recipe — Bulk-promote a project or everything

`occ releasebinding generate` supports `--all` and `--project` modes for promoting many components at once. If a `bulk-gitops-release` Workflow is installed on the cluster, it does the same thing via a WorkflowRun + PR.

Two paths:

- **CLI from a workstation** — fast, low ceremony, useful for sandbox / dev work.
- **`bulk-gitops-release` Workflow** — runs in the cluster, produces a PR. Audit trail, no local credentials needed, good for production promotions.

## Path A — CLI bulk promote

### Whole project to one env

```bash
occ releasebinding generate \
  --mode file-system --root-dir <repo> \
  --project <project> \
  --target-env staging --use-pipeline standard
```

Generates one ReleaseBinding per component in the project, each pointing at that component's latest ComponentRelease. Files land under `namespaces/<ns>/projects/<project>/components/*/release-bindings/<component>-staging.yaml`.

`--use-pipeline` is **required** with `--project` (same as `--all`). Without it the command errors.

### Everything across all projects in the namespace

```bash
occ releasebinding generate --all \
  --mode file-system --root-dir <repo> \
  --target-env production --use-pipeline standard
```

`--use-pipeline` is **required** with `--all`. Generates ReleaseBindings for every Component with a ComponentRelease, across every Project in the repo.

### Commit, PR, wait

Branch `bulk-release/<scope>-<target-env>-<ts>`, paths `namespaces/<ns>/projects/`, message `"Bulk promote <scope> to <target-env>"`. `<scope>` = `project-<project>` or `all-projects`. Canonical flow in [`../authoring.md`](../authoring.md) *Git workflow*.

### Verify after merge

```bash
flux get kustomizations -A
occ releasebinding list -n <ns> --project <project>      # all the new bindings ready
# Spot-check a few:
occ releasebinding get <component>-<target-env> -n <ns>
```

## Path B — `bulk-gitops-release` Workflow

If the cluster has `bulk-gitops-release` installed, trigger a WorkflowRun:

```bash
kubectl apply -f - <<EOF
apiVersion: openchoreo.dev/v1alpha1
kind: WorkflowRun
metadata:
  name: bulk-promote-<scope>-<target-env>-$(date +%Y%m%d-%H%M%S)
  namespace: <ns>
spec:
  workflow:
    kind: Workflow
    name: bulk-gitops-release
    parameters:
      scope:
        all: false                                # true = all projects; false + projectName = one project
        projectName: <project>
      gitops:
        repositoryUrl: https://github.com/<your-org>/<your-gitops-repo>
        branch: main
        targetEnvironment: <target-env>
        deploymentPipeline: standard
EOF
```

**WorkflowRuns are imperative** — don't commit them to Git. Watch:

```bash
occ workflowrun list -n <ns>
occ workflowrun get <run-name> -n <ns>
```

The workflow produces a PR on the GitOps repo with the ReleaseBindings. Review and merge.

Parameters:

| Parameter | Required | Default | Notes |
|---|---|---|---|
| `scope.all` | no | `false` | `true` = all projects |
| `scope.projectName` | yes | | Still required even when `all: true` (placeholder) |
| `gitops.repositoryUrl` | yes | | URL of the GitOps repo |
| `gitops.branch` | no | `main` | Target branch |
| `gitops.targetEnvironment` | no | `development` | Env to promote to |
| `gitops.deploymentPipeline` | yes | | Pipeline name |

## Choosing between A and B

| | Path A — CLI | Path B — Workflow |
|---|---|---|
| **Auth** | local `occ` credentials | cluster-side; uses `gitops-token` from `ClusterSecretStore` |
| **Audit trail** | local commit history + git host | WorkflowRun records on the cluster |
| **Speed** | fast (seconds for the generate, minutes for merge + reconcile) | minutes for the workflow + merge + reconcile |
| **Prerequisite** | `occ` configured locally | `bulk-gitops-release` workflow installed by PE |
| **Best for** | sandbox, dev / staging promotions, ad-hoc | production promotions, scheduled / triggered automation |

## Per-environment overrides during bulk promote

`occ releasebinding generate --project / --all` produces bindings without overrides. If specific components need different `componentTypeEnvironmentConfigs` / `traitEnvironmentConfigs` / `workloadOverrides` per env, you'll edit those bindings post-generation. See [`override-per-environment.md`](./override-per-environment.md).

For consistent overrides across many components (e.g. "everything gets 2 replicas in staging"), consider authoring a kustomize overlay over the bindings — but that's a layout choice. Default OpenChoreo flow is per-file edits.

## Rollback for a bulk promote

Run the same command with `--component-release` pointing at the previous release per component — that's tricky in bulk (you'd need to enumerate the previous releases). Easier: edit the bindings in place to repoint `spec.releaseName`. Or revert the bulk-promote PR via git revert and reconcile.

`git revert <bulk-promote-sha>` is the cleanest path for "I just promoted N components and need to roll all of them back".

## Gotchas

- **`--all` and `--project` both require `--use-pipeline`.** Without it, the command errors.
- **Latest-as-default in bulk mode.** `--component-release` doesn't apply to `--project` / `--all`; each component's binding gets that component's latest release. If a new build lands during the bulk promote, you may capture a mix of release versions across components. For deterministic promotion of a known-good set, freeze releases first (commit-and-merge them) then run the bulk promote.
- **Big PRs are scary.** Bulk promote of 30 components produces 30 ReleaseBinding file changes. Reviewer attention drops. Consider splitting per project, or pairing with a release notes summary.
- **WorkflowRun produces a single PR.** All bindings in one diff. Same trade-off as above.
- **`bulk-gitops-release` Workflow requires the GitOps repo URL** in the parameters. If the workflow CR was captured from another cluster, its hard-coded `gitops-repo-url` may still point at that old repo until updated.

## Related

- [`promote.md`](./promote.md) — single-component promotion (covers the rollback semantics)
- [`override-per-environment.md`](./override-per-environment.md)
- [`onboard-component-byo.md`](./onboard-component-byo.md), [`onboard-component-source-build.md`](./onboard-component-source-build.md)
