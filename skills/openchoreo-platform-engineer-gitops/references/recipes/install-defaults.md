# Recipe — Install the default platform resources

Materialise the OpenChoreo defaults into a scaffolded GitOps repo:

- **From `openchoreo/openchoreo` `samples/getting-started/`** — `Project`, `Environment`s, `DeploymentPipeline`, the four `ClusterComponentType`s (`service`, `web-application`, `worker`, `scheduled-task`), and the `ClusterTrait` (`observability-alert-rule`).
- **From `openchoreo/sample-gitops`** — the GitOps-mode build-and-release `Workflow` CRs (`docker-gitops-release`, `google-cloud-buildpacks-gitops-release`, `react-gitops-release`, `bulk-gitops-release`) and their Argo `ClusterWorkflowTemplate`s.

Optionally also the extra shapes from `sample-gitops` — `database` / `message-broker` ComponentTypes and `persistent-volume` / `api-management` Traits.

Run during scaffolding (per [`scaffold.md`](./scaffold.md) §6 `Replace with defaults`), or standalone in operating mode to top up a partially-scaffolded repo.

All upstream fetches use **WebFetch** against the raw GitHub URLs in [`../authoring.md`](../authoring.md). No local cache in the skill.

## Critical pre-step — CI workflow gotcha

The vanilla install at `samples/getting-started/` ships **CI workflows** (`dockerfile-builder`, `paketo-buildpacks-builder`, `gcp-buildpacks-builder`, `ballerina-buildpack-builder`) that build images and write the `Workload` CR **directly to the cluster API server**. **They don't fit GitOps mode** — Flux would revert the Workload. We **never** install those.

For GitOps, install the equivalents from `sample-gitops`:

| Vanilla (don't use) | GitOps equivalent (use) |
| --- | --- |
| `dockerfile-builder` | `docker-gitops-release` |
| `gcp-buildpacks-builder` | `google-cloud-buildpacks-gitops-release` |
| `paketo-buildpacks-builder` | (no direct GitOps equivalent — use `google-cloud-buildpacks-gitops-release` for buildpack-style flows) |
| `ballerina-buildpack-builder` | (no direct GitOps equivalent — use `docker-gitops-release` with a Ballerina-built image) |
| (no vanilla equivalent) | `react-gitops-release` (Node + nginx for SPAs) |
| (no vanilla equivalent) | `bulk-gitops-release` (promotion-only, no build) |

The four GitOps `Workflow` CRs each pair with a `ClusterWorkflowTemplate` in `platform-shared/cluster-workflow-templates/argo/`.

See [`../authoring.md`](../authoring.md) *Vanilla CI workflows aren't GitOps-compatible* for the full reasoning.

## Preconditions

- A scaffolded repo (directory tree per [`scaffold.md`](./scaffold.md) §5).
- `occ` configured + active context confirmed with the user (surface the context name, control-plane URL, and namespace).
- `kubectl` **only if** you also plan to delete cluster-side originals (Replace flow cleanup). For the pure install-defaults-and-commit case, just `occ` + WebFetch is enough — Flux handles the apply when the merged PR reconciles.
- For the build-and-release workflows: a `ClusterSecretStore` (typically named `default`) on the workflow plane resolves `git-token` and `gitops-token`. Provision via [`install-flux-and-secrets.md`](./install-flux-and-secrets.md) if missing.

## User choices upfront

Ask the user which categories to install (multi-select):

| Category | Default | Notes |
| --- | --- | --- |
| Project / Environments / DeploymentPipeline | Yes | Skip if the user wants a different naming convention. |
| ClusterComponentTypes (`service`, `web-application`, `worker`, `scheduled-task`) | Yes | |
| ClusterTrait (`observability-alert-rule`) | Yes | |
| GitOps Workflows + Argo templates | Yes | |
| Extra ComponentTypes (`database`, `message-broker`) | No | |
| Extra Traits (`persistent-volume`, `api-management`) | No | |

Plus the scope choice (single question, applies to everything that can be scoped — CCTs / Traits / Workflows):

| Choice | Default | Notes |
| --- | --- | --- |
| Cluster-scoped (`ClusterComponentType` / `ClusterTrait` / `ClusterWorkflow`) | Yes | Matches the vanilla install pattern. Visible to every namespace. |
| Namespace-scoped (`ComponentType` / `Trait` / `Workflow`) | No | One-namespace install. Useful for tenancy isolation. |

See [`../authoring.md`](../authoring.md) *Cluster ↔ namespace scope* for the conversion mechanics — the source files in `samples/getting-started/` are cluster-scoped; the source files in `sample-gitops/` are namespace-scoped. The skill flips whichever doesn't match the user's choice.

## Steps

### 1. Project, Environments, DeploymentPipeline

GitOps-agnostic — copy as-is. Vanilla defaults from `samples/getting-started/`.

```bash
NS="<first-namespace>"

# Project
WebFetch https://raw.githubusercontent.com/openchoreo/openchoreo/main/samples/getting-started/project.yaml
# → save to namespaces/$NS/projects/default/project.yaml

# Environments (multi-doc YAML with development / staging / production)
WebFetch https://raw.githubusercontent.com/openchoreo/openchoreo/main/samples/getting-started/environments.yaml
# → save to namespaces/$NS/platform/infra/environments/environments.yaml
# (Optionally split per env for cleaner diffs)

# DeploymentPipeline
WebFetch https://raw.githubusercontent.com/openchoreo/openchoreo/main/samples/getting-started/deployment-pipeline.yaml
# → save to namespaces/$NS/platform/infra/deployment-pipelines/default.yaml
```

If `$NS != default`, update `metadata.namespace:` and the `Project.spec.deploymentPipelineRef.name` if you renamed the pipeline. The shipped Environments target `ClusterDataPlane/default`; if that doesn't exist on the cluster, Environments sit at `Ready=False` until a plane is registered (install-side).

### 2. ClusterComponentTypes (or ComponentTypes)

Fetch each, transform per the user's scope choice, then write.

```bash
for FILE in service webapp worker scheduled-task; do
  WebFetch https://raw.githubusercontent.com/openchoreo/openchoreo/main/samples/getting-started/component-types/$FILE.yaml
done
```

**Required transforms:**

1. **Scope swap** (if user picked namespace-scoped):
   - `kind: ClusterComponentType` → `kind: ComponentType`
   - Add `metadata.namespace: $NS`
   - Save under `namespaces/$NS/platform/component-types/` instead of `platform-shared/component-types/`
2. **`allowedWorkflows[]` rewrite** — the vanilla files list the vanilla CI workflows. Replace with the GitOps workflows (the cluster-scoped or namespace-scoped variant matching the user's choice):

```yaml
# Vanilla — don't keep:
allowedWorkflows:
  - kind: ClusterWorkflow
    name: paketo-buildpacks-builder
  - kind: ClusterWorkflow
    name: gcp-buildpacks-builder
  - kind: ClusterWorkflow
    name: dockerfile-builder
  - kind: ClusterWorkflow
    name: ballerina-buildpack-builder

# GitOps replacement (cluster-scoped):
allowedWorkflows:
  - kind: ClusterWorkflow
    name: docker-gitops-release
  - kind: ClusterWorkflow
    name: google-cloud-buildpacks-gitops-release
```

The `web-application` ComponentType additionally allows `react-gitops-release` for SPA builds. Update each ComponentType's `allowedWorkflows[]` per what the workflow does:

| ComponentType | Recommended `allowedWorkflows[]` |
| --- | --- |
| `service` | `docker-gitops-release`, `google-cloud-buildpacks-gitops-release` |
| `web-application` | `docker-gitops-release`, `google-cloud-buildpacks-gitops-release`, `react-gitops-release` |
| `worker` | `docker-gitops-release`, `google-cloud-buildpacks-gitops-release` |
| `scheduled-task` | `docker-gitops-release`, `google-cloud-buildpacks-gitops-release` |

### 3. ClusterTrait (or Trait)

```bash
WebFetch https://raw.githubusercontent.com/openchoreo/openchoreo/main/samples/getting-started/component-traits/alert-rule-trait.yaml
```

Save as `platform-shared/traits/observability-alert-rule.yaml` (cluster) or `namespaces/$NS/platform/traits/observability-alert-rule.yaml` (namespace). Rename file if the source file name differs from the resource name.

Same scope swap as §2 if needed.

### 4. GitOps Workflow CRs (Workflows or ClusterWorkflows)

Source is namespace-scoped in `sample-gitops`. Flip to cluster-scoped if the user chose that.

```bash
for FILE in docker-with-gitops-release google-cloud-buildpacks-gitops-release react-gitops-release bulk-gitops-release; do
  WebFetch https://raw.githubusercontent.com/openchoreo/sample-gitops/main/namespaces/default/platform/workflows/$FILE.yaml
done
```

**Required transforms** (all four files):

1. **Scope swap** if cluster-scoped chosen:
   - `kind: Workflow` → `kind: ClusterWorkflow`
   - Drop `metadata.namespace`
   - Add `spec.workflowPlaneRef: { kind: ClusterWorkflowPlane, name: default }` if not present
   - Save under `platform-shared/workflows/` instead of `namespaces/$NS/platform/workflows/`
2. **Hard-coded `runTemplate.spec.arguments.parameters`** — edit each:

   | Parameter | Sample-gitops default | What to set |
   | --- | --- | --- |
   | `gitops-repo-url` | `https://github.com/openchoreo/sample-gitops` | The remote URL of *this* scaffolded GitOps repo |
   | `gitops-branch` | `main` | The repo's branch from scaffolding |
   | `registry-url` | sample-gitops default | Registry the workflow plane can push to — ask the user. |
   | `image-name` | `${parameters.projectName}-${parameters.componentName}-image` | Usually leave |
   | `image-tag` | `v1` | Usually leave |

3. **Workflow name** — the file name `docker-with-gitops-release.yaml` carries `metadata.name: docker-gitops-release` (no `with-`). The resource name is what `allowedWorkflows[]` and `Component.spec.workflow.name` reference — don't rename it.

### 5. Argo ClusterWorkflowTemplates

These don't change between cluster / namespace-scoped Workflow CRs — Argo `ClusterWorkflowTemplate` is always cluster-scoped.

```bash
for FILE in docker-with-gitops-release google-cloud-buildpacks-gitops-release react-gitops-release bulk-gitops-release; do
  WebFetch https://raw.githubusercontent.com/openchoreo/sample-gitops/main/platform-shared/cluster-workflow-templates/argo/$FILE-template.yaml
done
```

Save under `platform-shared/cluster-workflow-templates/argo/`. No edits needed — they're generic across clusters.

### 6. (Optional) Extra shapes

If the user opted in, fetch from `sample-gitops` and apply the scope swap if needed:

```bash
# Extra ComponentTypes
WebFetch https://raw.githubusercontent.com/openchoreo/sample-gitops/main/namespaces/default/platform/component-types/database.yaml
WebFetch https://raw.githubusercontent.com/openchoreo/sample-gitops/main/namespaces/default/platform/component-types/message-broker.yaml

# Extra Traits
WebFetch https://raw.githubusercontent.com/openchoreo/sample-gitops/main/namespaces/default/platform/traits/persistent-volume.yaml
WebFetch https://raw.githubusercontent.com/openchoreo/sample-gitops/main/namespaces/default/platform/traits/api-management.yaml
```

These are namespace-scoped in source. For each, apply the user's scope choice (same as §2 and §3). Update each new `(Cluster)ComponentType.allowedWorkflows[]` per the table in §2.

The `database` and `message-broker` ComponentTypes pair naturally with the `persistent-volume` Trait — surface this to the user.

### 7. Commit

```bash
git checkout -b platform/install-defaults-$(date +%Y%m%d-%H%M%S)
git add namespaces/<ns>/ platform-shared/
git status                                              # show before committing
git commit -s -m "platform: scaffold default project / environments / pipeline / CCTs / Traits / GitOps workflows"
git push origin HEAD                                    # only after user confirmation
gh pr create --fill                                     # only after user confirmation
```

For brand-new repos with no protected branch, the user may prefer to commit directly to `main` — match the repo profile.

### 8. Verify after merge

```bash
flux get kustomizations -A                              # READY=True for platform-shared and platform
occ project get default -n <ns>
occ environment list -n <ns>                            # development, staging, production
occ deploymentpipeline get default -n <ns>
occ clustercomponenttype list                           # or `occ componenttype list -n <ns>`
occ clustertrait list                                   # or `occ trait list -n <ns>`
occ clusterworkflow list                                # or `occ workflow list -n <ns>`
kubectl get clusterworkflowtemplate                     # docker-gitops-release etc.
```

Smoke-test with a `WorkflowRun` if the developer side is ready — that's a developer-skill concern.

## Gotchas

- **`allowedWorkflows[]` is the most common omission.** A ComponentType still referencing vanilla CI workflows will reject any Component using `docker-gitops-release` with `WorkflowNotAllowed`.
- **`kind:` mismatch on `allowedWorkflows[]` / `allowedTraits[]`.** A cluster-scoped ComponentType referencing a namespace-scoped Workflow / Trait fails admission. See [`../authoring.md`](../authoring.md) *Cluster ↔ namespace scope* — cross-scope rule.
- **`gitops-repo-url` mismatch** in the Workflow `runTemplate`s. If left as `https://github.com/openchoreo/sample-gitops`, every build opens PRs against `sample-gitops` itself. Edit before merging.
- **`registry-url`** must match a registry the workflow plane can push to and the data plane can pull from. Ask the user during scaffolding — sample-gitops ships a placeholder.
- **`ClusterSecretStore` name** in the Workflow CRs' `ExternalSecret`s is hard-coded to `default`. If the cluster's store has a different name, edit the Workflow CR or rename the store.
- **Argo Workflows must be installed on the WorkflowPlane.** Verify: `kubectl get clusterworkflowtemplate` against the workflow plane. If empty, the `ClusterWorkflowTemplate` CRD isn't installed — that's an install-side fix.
- **Environments depend on a registered DataPlane.** `ClusterDataPlane/default` must exist before §1 reconciles. Without it, the Environments stay `Ready=False`.

## Related

- [`scaffold.md`](./scaffold.md) — the scaffolding flow that calls this recipe via *Replace with defaults*
- [`install-flux-and-secrets.md`](./install-flux-and-secrets.md) — Flux install + `git-token` / `gitops-token` / `git-credentials` provisioning
- [`../authoring.md`](../authoring.md) — upstream URLs, scope swap, CI gotcha, repo paths
