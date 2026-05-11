# Authoring

Where CRD shapes come from, how to convert between scopes, the CI-workflow gotcha, and the git workflow.

## Shape-lookup decision table

Four sources. Pick by what you're authoring; don't mix them up.

| Need | Source |
| --- | --- |
| Something similar already lives on the cluster | `occ <kind> get <name>` — strip `status:`, `metadata.managedFields:`, `metadata.creationTimestamp:`, `metadata.resourceVersion:`, `metadata.uid:` |
| Vanilla defaults: `Project`, `Environment`, `DeploymentPipeline`, the four shipped `ClusterComponentType`s (`service`, `web-application`, `worker`, `scheduled-task`), the shipped `ClusterTrait` (`observability-alert-rule`) | `openchoreo/openchoreo` → `samples/getting-started/` (see *Vanilla defaults* below) |
| GitOps Workflow CRs (`docker-gitops-release`, `google-cloud-buildpacks-gitops-release`, `react-gitops-release`, `bulk-gitops-release`) + their Argo `ClusterWorkflowTemplate`s | `openchoreo/sample-gitops` (see *GitOps resources* below) |
| Extra ComponentTypes (`database`, `message-broker`) + extra Traits (`persistent-volume`, `api-management`) | `openchoreo/sample-gitops` (see *Extra shapes* below) |
| Anything else (`SecretReference`, `AuthzRole` + binding, `ObservabilityAlertRule`, `NotificationChannel`, plane CRDs, …) | `llms.txt` API reference for the running `occ` minor (see *llms.txt* below) |

All upstream sources are fetched via WebFetch; no local copies kept in the skill.

## Vanilla defaults — `samples/getting-started/`

Source: <https://github.com/openchoreo/openchoreo/tree/main/samples/getting-started>

Raw file URLs follow `https://raw.githubusercontent.com/openchoreo/openchoreo/main/samples/getting-started/<path>`:

| Resource | Path |
| --- | --- |
| Combined manifest | `all.yaml` |
| Default Project | `project.yaml` |
| 3 Environments (dev / staging / production) | `environments.yaml` |
| Default DeploymentPipeline | `deployment-pipeline.yaml` |
| 4 ClusterComponentTypes | `component-types/{service,webapp,worker,scheduled-task}.yaml` |
| ClusterTrait | `component-traits/alert-rule-trait.yaml` |
| Vanilla CI workflows (do NOT use for GitOps — see *CI gotcha*) | `ci-workflows/{dockerfile,paketo-buildpacks,gcp-buildpacks,ballerina-buildpack}-builder.yaml` |
| Vanilla Argo `ClusterWorkflowTemplate`s for the CI workflows | `workflow-templates/*.yaml` |

These ship cluster-scoped (`ClusterComponentType` / `ClusterTrait` / `ClusterWorkflow`). To use namespace-scoped, see *Cluster ↔ namespace scope* below.

## GitOps resources — `sample-gitops`

Source: <https://github.com/openchoreo/sample-gitops>

Raw file URLs follow `https://raw.githubusercontent.com/openchoreo/sample-gitops/main/<path>`:

| Resource | Path |
| --- | --- |
| GitOps Workflow CRs (4) — build + GitOps PR | `namespaces/default/platform/workflows/{docker-with-gitops-release,google-cloud-buildpacks-gitops-release,react-gitops-release,bulk-gitops-release}.yaml` |
| Argo `ClusterWorkflowTemplate`s for the above | `platform-shared/cluster-workflow-templates/argo/{docker-with-gitops-release,google-cloud-buildpacks-gitops-release,react-gitops-release,bulk-gitops-release}-template.yaml` |
| Flux entrypoint reference | `flux/{gitrepository,namespaces-kustomization,platform-shared-kustomization,oc-demo-platform-kustomization,oc-demo-projects-kustomization}.yaml` |

> The GitOps Workflow CRs in `sample-gitops` are **namespace-scoped** (`kind: Workflow`, `metadata.namespace: default`). The skill defaults to **cluster-scoped** (`kind: ClusterWorkflow`, drop `metadata.namespace`) unless the user asks otherwise — convert per *Cluster ↔ namespace scope* below.

> The GitOps `runTemplate`s contain hard-coded values inside `runTemplate.spec.arguments.parameters` that must be edited per cluster:
>
> - `gitops-repo-url` — the remote URL of *this* scaffolded GitOps repo
> - `gitops-branch` — the repo's main branch
> - `registry-url` — container registry the workflow plane can push to (`host.k3d.internal:10082` is the k3d-local default; replace for non-k3d clusters)
> - `image-name`, `image-tag` — naming convention; usually leave

## Extra shapes — `sample-gitops`

Additional ComponentTypes and Traits not in the vanilla defaults but commonly needed.

| Kind | Path | Notes |
| --- | --- | --- |
| `ComponentType/database` | `namespaces/default/platform/component-types/database.yaml` | Stateful DB shape; pairs with `persistent-volume` Trait |
| `ComponentType/message-broker` | `namespaces/default/platform/component-types/message-broker.yaml` | Broker shape (NATS, Kafka, etc.) |
| `Trait/persistent-volume` | `namespaces/default/platform/traits/persistent-volume.yaml` | PVC + Deployment patches for volume mount |
| `Trait/api-management` | `namespaces/default/platform/traits/api-management.yaml` | API gateway shaping (rate limits, auth) |
| `Trait/observability-alert-rule` | `namespaces/default/platform/traits/observability-alert-rule.yaml` | Same as the vanilla default but namespace-scoped |

These are namespace-scoped in `sample-gitops`. Use the cluster↔namespace scope swap to flip if needed.

## `llms.txt` — for everything else

The version-pinned LLM-friendly documentation index:

```
https://openchoreo.dev/llms.txt              # latest stable
https://openchoreo.dev/llms-v<minor>.x.txt   # specific minor
https://openchoreo.dev/llms-next.txt         # bleeding edge
```

Parse `occ version` → `Client.Version` → `$OCC_MINOR` (e.g. `v1.0.x`). Match against the `llms.txt` header; if it lags, fetch `llms-$OCC_MINOR.txt`.

API reference URLs follow:

```
https://openchoreo.dev/docs/reference/api/<scope>/<kind>.md
```

`<scope>` is one of:

| Scope | Kinds |
| --- | --- |
| `application` | Project, Component, Workload, WorkflowRun |
| `platform` | DataPlane / ClusterDataPlane, WorkflowPlane / ClusterWorkflowPlane, ObservabilityPlane / ClusterObservabilityPlane, ComponentType / ClusterComponentType, Trait / ClusterTrait, Workflow / ClusterWorkflow, SecretReference, DeploymentPipeline (hyphenated URL: `deployment-pipeline.md`), Environment, ReleaseBinding, ObservabilityAlertRule, ObservabilityAlertsNotificationChannel, AuthzRole / ClusterAuthzRole, AuthzRoleBinding / ClusterAuthzRoleBinding |
| `runtime` | ComponentRelease, RenderedRelease (both controller-managed; **never hand-author**) |

Most kinds use lowercase concatenation (`componenttype.md`); `DeploymentPipeline` is hyphenated.

When authoring from `llms.txt`, cite the page in a comment:

```yaml
# shape: https://openchoreo.dev/docs/reference/api/platform/<kind>.md (occ v1.0.x)
apiVersion: openchoreo.dev/v1alpha1
kind: <Kind>
...
```

## Cluster ↔ namespace scope

ComponentType / Trait / Workflow each come in two scopes:

| Cluster-scoped | Namespace-scoped |
| --- | --- |
| `ClusterComponentType` | `ComponentType` |
| `ClusterTrait` | `Trait` |
| `ClusterWorkflow` | `Workflow` |

**They're interchangeable in shape.** Conversion is mechanical:

| Direction | Steps |
| --- | --- |
| Cluster → namespace | (a) `kind: ClusterX` → `kind: X` &nbsp; (b) add `metadata.namespace: <ns>` &nbsp; (c) on every referrer's `allowedWorkflows[].kind` / `allowedTraits[].kind`, swap `Cluster*` → `*` |
| Namespace → cluster | (a) `kind: X` → `kind: ClusterX` &nbsp; (b) drop `metadata.namespace:` &nbsp; (c) on every referrer's `allowedWorkflows[].kind` / `allowedTraits[].kind`, swap `*` → `Cluster*` |

**Cross-scope rule** (per the OpenChoreo docs): a `ClusterComponentType` may only reference `ClusterTrait` / `ClusterWorkflow` in its allow-lists. A namespace-scoped `ComponentType` may reference both cluster- and namespace-scoped variants.

> **Where to commit each scope:**
>
> - Cluster-scoped → `platform-shared/<topic>/<name>.yaml`
> - Namespace-scoped → `namespaces/<ns>/platform/<topic>/<name>.yaml`

## Vanilla CI workflows aren't GitOps-compatible

Critical gotcha. The vanilla CI workflows shipped at `samples/getting-started/ci-workflows/`:

- `dockerfile-builder`
- `paketo-buildpacks-builder`
- `gcp-buildpacks-builder`
- `ballerina-buildpack-builder`

…end their pipeline with a `generate-workload-cr` step that **writes the `Workload` CR directly to the cluster API server** via the OpenChoreo API (OAuth client-credentials). In a GitOps repo, **Flux will revert that Workload on the next reconcile**, because the workload isn't in Git.

The GitOps equivalents (from `sample-gitops`) end their pipeline with a different sequence:

```text
clone-source → build-image → push-image → extract-descriptor →
clone-gitops → create-feature-branch → generate-gitops-resources → git-commit-push-pr
```

They build the image, generate the `Workload` + `ComponentRelease` + `ReleaseBinding` manifests using `occ` file-mode, and open a PR against the GitOps repo. Once merged, Flux deploys them.

**Rules:**

1. **Never carry vanilla CI workflows into a GitOps repo.** If they're already on the cluster from a non-GitOps install, surface the recommendation to **Replace with the GitOps versions** when scaffolding.
2. **Always rewrite `ClusterComponentType.allowedWorkflows[]`** when installing defaults under GitOps: swap the vanilla workflow names (`dockerfile-builder` etc.) for the GitOps names (`docker-gitops-release` etc.), and the `kind:` field for the chosen scope.

## Repo paths

Per `gitops/overview.md` *Repository Organization Patterns*. Default is the mono-repo layout below.

| Resource | Path |
| --- | --- |
| `ClusterComponentType` | `platform-shared/component-types/<name>.yaml` |
| `ClusterTrait` | `platform-shared/traits/<name>.yaml` |
| `ClusterWorkflow` | `platform-shared/workflows/<name>.yaml` |
| `ClusterAuthzRole` / `ClusterAuthzRoleBinding` | `platform-shared/authz/{roles,role-bindings}/<name>.yaml` |
| Argo `ClusterWorkflowTemplate` (for GitOps Workflow CRs) | `platform-shared/cluster-workflow-templates/argo/<name>.yaml` |
| `ComponentType` (namespace-scoped) | `namespaces/<ns>/platform/component-types/<name>.yaml` |
| `Trait` (namespace-scoped) | `namespaces/<ns>/platform/traits/<name>.yaml` |
| `Workflow` (namespace-scoped) | `namespaces/<ns>/platform/workflows/<name>.yaml` |
| `Environment` | `namespaces/<ns>/platform/infra/environments/<name>.yaml` |
| `DeploymentPipeline` | `namespaces/<ns>/platform/infra/deployment-pipelines/<name>.yaml` |
| `SecretReference` | `namespaces/<ns>/platform/secret-references/<name>.yaml` |
| `AuthzRole` / `AuthzRoleBinding` | `namespaces/<ns>/platform/authz/{roles,role-bindings}/<name>.yaml` |
| `ObservabilityAlertRule` / `NotificationChannel` | `namespaces/<ns>/platform/observability/{alert-rules,notification-channels}/<name>.yaml` (convention) |
| `Namespace` | `namespaces/<ns>/namespace.yaml` |
| Application resources (Project, Component, Workload, …) | `namespaces/<ns>/projects/<project>/...` — out of scope for this skill |
| Flux's own resources | `flux/` (single cluster) or `clusters/<name>/` (multi-cluster), at the repo root |

For multi-repo, repo-per-project, repo-per-component, separate-releasebindings-repo, environment-based, or hybrid patterns (per the docs' *Flexible Repository Structures*), the resource model is identical — only where the files live differs. Capture the chosen pattern in the repo profile during scaffolding.

## Sequencing inside one PR

Controllers reconcile by content, not order — co-committed resources are fine even when one references another. Common pairings:

- `Environment`(s) → `DeploymentPipeline`
- `(Cluster)ComponentType` / `(Cluster)Trait` → `Component` (developer side; out of scope here)
- `(Cluster)DataPlane` → `Environment` (`dataPlaneRef` is **immutable** — re-pointing means delete + recreate)
- `(Cluster)SecretStore` (provisioned outside this skill) → `SecretReference`

Across Kustomizations, Flux's `dependsOn` chain handles ordering: `platform-shared/` → `namespaces/<ns>/platform/` → `namespaces/<ns>/projects/`.

## Git workflow

| Scope | Branch convention |
| --- | --- |
| Platform changes | `platform/<scope>-<ts>` |
| Initial scaffold | `chore/scaffold-gitops-<ts>` (or commit directly on `main` for a brand-new repo) |

`<ts>` = `$(date +%Y%m%d-%H%M%S)`. Always `git commit -s` (DCO is required upstream). Open with the host CLI (`gh` / `glab` / `bb`); poll until merged when the repo profile says PR-and-wait:

```bash
until gh pr view <number> --json state -q .state | grep -q MERGED; do sleep 30; done
```

Don't force-push to a shared branch — fix-forward. **Don't open a PR or push without explicit user confirmation.**

## `occ apply -f <file>` and `kubectl apply -f`

Single-file only for `occ apply`. Reserved for pre-Flux one-shot bootstrap — typically the `Namespace` and any `ClusterDataPlane` the rest of the repo references.

`kubectl apply -f flux/` is the one-time Flux bootstrap (after which Flux pulls from Git). Argo `ClusterWorkflowTemplate`s land via Flux through the `platform-shared/` Kustomization; no direct `kubectl apply` needed once Flux is wired.

## Auth and context

- `occ login` — OIDC interactive; `--client-credentials --client-id <id> --client-secret <secret> --credential <name>` for service accounts.
- `occ config context list` — what every session should verify before touching the cluster.
- `kubectl config current-context` + `kubectl cluster-info` — verify the same cluster as `occ`.

Reads (`<kind> get`, `<kind> list`) and `apply -f` need a live `occ` context.
