# Authoring

Where CRD shapes come from, how to convert between scopes, the CI-workflow gotcha, and the git workflow.

## Shape-lookup decision table

Pick by what you're authoring; don't mix them up.

| Need | Source |
| --- | --- |
| Authoring any CRD from scratch — full schema with optional fields | **`./scripts/fetch-page.sh --exact --title "<Kind>"`** (see *Fetching CRD shapes* below). Primary source. |
| Default `Project` / `Environment`s / `DeploymentPipeline` / `ClusterComponentType`s / `ClusterTrait`, and the vanilla CI `ClusterWorkflow`s | **`./scripts/extract-resources.sh defaults --list`** (see *Resource extraction* below) |
| GitOps build-and-release Workflows + paired Argo `ClusterWorkflowTemplate`s | **`./scripts/extract-resources.sh gitops-workflows --list`** (see *Resource extraction* below) |
| Discover what extensions exist on the platform (community modules, integrations, ComponentTypes, Workflows, Skills, Agents) | The per-type ecosystem catalogs linked from <https://openchoreo.dev/llms.txt> *## Ecosystem* — see *Discovering extensions* below |

Upstream Git files are fetched at the version pinned to the cluster (see *Pin upstream fetches* below). The docs are fetched via `fetch-page.sh`, which handles version resolution internally.

### Pin upstream fetches to the cluster's version

`samples/getting-started/all.yaml` ships in `openchoreo/openchoreo`, which is tagged per minor. Set `OCC_TAG` before running `extract-resources.sh`:

```bash
OCC_TAG=$(occ version --short 2>/dev/null | awk '/Client Version/ {print $3}')
# e.g. v1.0.1 — exported into the env, consumed by the script:
export OCC_TAG
./scripts/extract-resources.sh defaults --list
```

The GitOps workflow files live in `openchoreo/sample-gitops`, which is **not yet tagged** — `GITOPS_TAG` defaults to `main`. When sample-gitops starts tagging releases, export `GITOPS_TAG` to match.

Never leave the defaults pointing at `main` for production work — that branch may carry CEL helpers or schema fields the cluster's controllers don't recognise yet.

For docs (`openchoreo.dev`), use the rendered site as-is. The `.md` endpoints already have version substitutions baked in.

## Resource extraction — `scripts/extract-resources.sh`

The script is a pure extractor: it fetches + prints raw YAML to stdout, never writes files, never transforms. The agent does scope swap, `allowedWorkflows[]` rewrite, runTemplate edits, and PR open.

```bash
./scripts/extract-resources.sh defaults --list
./scripts/extract-resources.sh defaults --kind <Kind> [--name <name>] [--include-vanilla-ci]
./scripts/extract-resources.sh gitops-workflows --list
./scripts/extract-resources.sh gitops-workflows --name <slug>
./scripts/extract-resources.sh --help
```

**`defaults` mode** splits `samples/getting-started/all.yaml` on `---` and filters by kind + name. Multi-doc output when a kind has multiple resources; docs are separated by `---`. The four vanilla CI `ClusterWorkflow`s are flagged inline in `--list` output and the script refuses to extract them without `--include-vanilla-ci` — they're not GitOps-compatible (see *Vanilla CI workflows aren't GitOps-compatible* below).

**`gitops-workflows` mode** fetches `openchoreo.dev/ecosystem/workflows.md`, greps for `gitops`, and resolves each entry's source URL to a raw URL pinned to `GITOPS_TAG`. `--name <slug>` emits the `Workflow` YAML followed by `---` followed by its paired `ClusterWorkflowTemplate`. The slug matches the resource name (the value used in `allowedWorkflows[].name`), not the catalog's display name.

End-to-end install procedure: [`recipes/install-defaults.md`](./recipes/install-defaults.md).

## Discovering extensions

The platform has more than just defaults. Per-type catalogs live under the `## Ecosystem` section of <https://openchoreo.dev/llms.txt>:

- <https://openchoreo.dev/ecosystem/component-types.md>
- <https://openchoreo.dev/ecosystem/workflows.md>
- <https://openchoreo.dev/ecosystem/modules.md>
- <https://openchoreo.dev/ecosystem/integrations.md>

Each entry is `- **Name** *(default?)* — description — source URL`. Source URL identifies the install path:

| URL pattern | Means |
| --- | --- |
| `openchoreo/openchoreo/.../samples/getting-started/component-types/` | Default ComponentType — use `extract-resources.sh defaults` |
| `openchoreo/openchoreo/.../samples/getting-started/ci-workflows/` | Vanilla CI workflow — **don't install in GitOps mode** |
| `openchoreo/sample-gitops/.../workflows/` | GitOps-mode workflow — use `extract-resources.sh gitops-workflows` |
| `openchoreo/community-modules/` | Helm-installed extension — different install path (out of scope for this recipe pass) |

Surface community options to the user when their request can't be satisfied by the defaults — e.g. AWS RDS PostgreSQL self-service, WSO2 Micro Integrator ComponentType.

## Fetching CRD shapes — `scripts/fetch-page.sh`

Use the bundled helper. It resolves the title against `llms.txt`, picks the right version, and prints the rendered Markdown. URL paths are not stable across minors — don't compose URLs by hand; use the script.

```bash
./scripts/fetch-page.sh --exact --title "ClusterComponentType"                    # CRD reference
./scripts/fetch-page.sh --exact --section "API Reference" --title "ComponentType"  # scope to CRD refs only
./scripts/fetch-page.sh --exact --title "ClusterComponentType" --version v1.0.x   # pin version
./scripts/fetch-page.sh --list                                                     # dump full llms.txt index
./scripts/list-versions.sh                                                         # supported minors
```

For **CRD reference pages**, pass the schema `kind` verbatim (`Component`, `ClusterComponentType`, `Trait`, `Workflow`, `Environment`, `DeploymentPipeline`, `SecretReference`, `AuthzRole`, `AuthzRoleBinding`, `ObservabilityAlertRule`, `ObservabilityAlertsNotificationChannel`, the plane kinds, …). These titles track schema kinds and stay stable. Add `--section "API Reference"` to restrict matching to the CRD-reference subtree — needed when a kind name also appears in guide-page titles.

For **conceptual / guide pages**, the title isn't the kind — run `--list` first to find the matching entry, then re-invoke with the exact title.

On a miss (no match / multiple matches / fetch failure), the script dumps the index — scoped to `--section` if given — to stdout so you can pick by hand.

> `ComponentRelease` and `RenderedRelease` are controller-managed — **never hand-author**.

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

Critical gotcha. The **four default `ClusterWorkflow`s** shipped by the platform install at `samples/getting-started/ci-workflows/`:

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

### Inspect any Workflow before trusting it

The four names above are just today's defaults — installs can ship more, and the platform team can author their own. When in doubt about a workflow you didn't author, inspect it:

```bash
occ clusterworkflow get <name>           # cluster-scoped
occ workflow get <name> -n <ns>          # namespace-scoped
```

Look at the last `steps:` entry of `spec.runTemplate` (or `templates[]` for `ClusterWorkflowTemplate` refs). GitOps-compatible workflows end with **`git-commit-push-pr`** (or equivalent — they push manifests to a Git repo and stop). Non-compatible workflows end with **`generate-workload-cr`** (writes a CR directly to the API) — those are the ones to avoid in GitOps mode.

**Rules:**

1. **Never carry non-GitOps workflows into a GitOps repo.** If they're already on the cluster from a non-GitOps install, surface the recommendation to **Replace with the GitOps versions** when scaffolding.
2. **Always rewrite `ClusterComponentType.allowedWorkflows[]`** when installing defaults under GitOps: swap the vanilla workflow names (`dockerfile-builder` etc.) for the GitOps names (`docker-gitops-release` etc.), and the `kind:` field for the chosen scope.

## Repo paths

Default is the mono-repo layout below. See [`concepts.md`](./concepts.md) *Repo layout* for the full tree (Flux + platform + developer paths).

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

Every platform change is a feature branch + PR. Recipes specify their branch prefix and commit-message scope; the rest is canonical:

```bash
git checkout -b <prefix>/<scope>-$(date +%Y%m%d-%H%M%S)
git add <files-from-recipe>
git status                                      # show before committing
git commit -s -m "<scope-prefix>: <action>"
git push origin HEAD                            # only after user confirmation
gh pr create --fill                             # only after user confirmation
until gh pr view <number> --json state -q .state | grep -q MERGED; do sleep 30; done
```

| Recipe area | Branch prefix | Commit-message scope |
| --- | --- | --- |
| Initial scaffold | `chore/scaffold-gitops-<ts>` (or commit directly on `main` for a brand-new repo) | `chore` |
| Author a `(Cluster)ComponentType` / `Trait` / `Workflow` / `Environment` / `DeploymentPipeline` / `SecretReference` / `AuthzRole` / `ObservabilityAlertRule` | `platform/<scope>-<ts>` | `platform` |

Always `git commit -s` (DCO is required upstream). Don't force-push to a shared branch — fix-forward. **Don't amend commits after a push** — create a new commit. Amending breaks force-push semantics, loses hook-failure recovery, and rewrites history collaborators may have pulled.

## `occ apply -f <file>` and `kubectl apply -f`

Single-file only for `occ apply`. Reserved for pre-Flux one-shot bootstrap — typically the `Namespace` and any `ClusterDataPlane` the rest of the repo references.

`kubectl apply -f flux/` is the one-time Flux bootstrap (after which Flux pulls from Git). Argo `ClusterWorkflowTemplate`s land via Flux through the `platform-shared/` Kustomization; no direct `kubectl apply` needed once Flux is wired.

## Auth and context

- `occ login` — OIDC interactive; `--client-credentials --client-id <id> --client-secret <secret> --credential <name>` for service accounts.
- `occ config context list` — what every session should verify before touching the cluster.
- `kubectl config current-context` + `kubectl cluster-info` — verify the same cluster as `occ`.

Reads (`<kind> get`, `<kind> list`) and `apply -f` need a live `occ` context.
