# Recipe — Install the default platform resources

Materialise the OpenChoreo defaults into a scaffolded GitOps repo. Two upstream sources, both routed through `./scripts/extract-resources.sh`:

- **`defaults` mode** — fetches `samples/getting-started/all.yaml` from `openchoreo/openchoreo`. Contains the default `Project`, three `Environment`s, `DeploymentPipeline`, four `ClusterComponentType`s, the default `ClusterTrait`, and the four vanilla CI `ClusterWorkflow`s (the script refuses to extract those for GitOps by default — see *Steps* §4).
- **`gitops-workflows` mode** — traverses `openchoreo.dev/ecosystem/workflows.md` filtered for `gitops`. Each match pairs the `Workflow` CR with its Argo `ClusterWorkflowTemplate`.

`./scripts/extract-resources.sh --help` for the full surface. The script prints raw YAML to stdout — the agent applies scope swap, `allowedWorkflows[]` rewriting, and `runTemplate` parameter editing, then commits.

Run during scaffolding (per [`scaffold.md`](./scaffold.md) §6 *Replace with defaults*), or standalone to top up a partially-scaffolded repo.

## Preconditions

- A scaffolded repo (directory tree per [`scaffold.md`](./scaffold.md) §5).
- `occ` configured + active context confirmed with the user (surface context name, control-plane URL, namespace).
- `OCC_TAG` env var set to the cluster's OpenChoreo version (otherwise the script fetches from `main`). See [`../authoring.md`](../authoring.md) *Pin upstream fetches*.
- For the build-and-release workflows: a `ClusterSecretStore` (typically named `default`) on the workflow plane that resolves `git-token` and `gitops-token`. Provision via [`install-flux-and-secrets.md`](./install-flux-and-secrets.md) if missing.

## User choices upfront

Three yes/no decisions, each with the default in brackets:

1. **Default `ClusterComponentType`s** (service, web-application, worker, scheduled-task) [Yes]
2. **Default `ClusterTrait`** (observability-alert-rule) [Yes]
3. **GitOps build-and-release workflows** (docker / google-cloud-buildpacks / react / bulk) [Yes]
   ⚠ Without these, developers can't build from source — only BYO image works.

The Project / Environments / DeploymentPipeline trio is always installed (they're the entry point for everything else).

Plus a single scope choice that applies to every bundle above:

| Scope | Default | Notes |
| --- | --- | --- |
| Cluster (`ClusterX`) | Yes | Visible to every namespace. Matches the vanilla install pattern. |
| Namespace (`X` under `namespaces/<ns>/platform/`) | No | One-namespace install for tenancy isolation. |

If both **CCTs** and **GitOps workflows** are selected, the agent additionally rewrites each CCT's `allowedWorkflows[]` to point at the GitOps workflows (§5).

## Steps

### 0. Always — Project / Environments / DeploymentPipeline

These three go together (pipeline references env names, project references pipeline name). Scope doesn't apply — they're namespace-scoped resources already.

```bash
NS=<your-namespace>
mkdir -p namespaces/$NS/projects/default
mkdir -p namespaces/$NS/platform/infra/environments
mkdir -p namespaces/$NS/platform/infra/deployment-pipelines

./scripts/extract-resources.sh defaults --kind Project --name default \
  > namespaces/$NS/projects/default/project.yaml
./scripts/extract-resources.sh defaults --kind Environment \
  > namespaces/$NS/platform/infra/environments/environments.yaml
./scripts/extract-resources.sh defaults --kind DeploymentPipeline --name default \
  > namespaces/$NS/platform/infra/deployment-pipelines/default.yaml
```

If `$NS != default`, update `metadata.namespace:` in each file. The shipped Environments target `ClusterDataPlane/default`; without that plane registered, Environments stay `Ready=False`.

### 1. `(Cluster)ComponentType`s

```bash
mkdir -p platform-shared/component-types
for name in service web-application worker scheduled-task; do
  ./scripts/extract-resources.sh defaults --kind ClusterComponentType --name $name \
    > platform-shared/component-types/$name.yaml
done
```

If `--scope namespace`:
- `kind: ClusterComponentType` → `kind: ComponentType`
- Add `metadata.namespace: $NS`
- Save under `namespaces/$NS/platform/component-types/` instead.

### 2. `(Cluster)Trait`

```bash
mkdir -p platform-shared/traits
./scripts/extract-resources.sh defaults --kind ClusterTrait --name observability-alert-rule \
  > platform-shared/traits/observability-alert-rule.yaml
```

Same scope swap as §1 if needed.

### 3. GitOps Workflow CRs + Argo templates

Discover what's available (script greps `ecosystem/workflows.md` for `gitops`):

```bash
./scripts/extract-resources.sh gitops-workflows --list
# output: <slug>\t<workflow-url>\t<template-url>
```

Extract each pair. The script emits the `Workflow` first, then `---`, then its paired `ClusterWorkflowTemplate`:

```bash
mkdir -p platform-shared/workflows
mkdir -p platform-shared/cluster-workflow-templates/argo

for name in docker-gitops-release google-cloud-buildpacks-gitops-release react-gitops-release bulk-gitops-release; do
  ./scripts/extract-resources.sh gitops-workflows --name $name > /tmp/$name.yaml
  # Split on --- — first doc is the Workflow, second is the ClusterWorkflowTemplate
  awk -v base="$name" -v wf_dir="platform-shared/workflows" -v tpl_dir="platform-shared/cluster-workflow-templates/argo" '
    BEGIN { n = 0 }
    /^---$/ { n++; next }
    n == 0 { print > (wf_dir "/" base ".yaml") }
    n == 1 { print > (tpl_dir "/" base "-template.yaml") }
  ' /tmp/$name.yaml
done
```

**Workflow CRs ship namespace-scoped (`kind: Workflow`, `metadata.namespace: default`).** With `--scope cluster` (the default), apply this swap to each `platform-shared/workflows/*.yaml`:
- `kind: Workflow` → `kind: ClusterWorkflow`
- Drop `metadata.namespace`
- Add `spec.workflowPlaneRef: { kind: ClusterWorkflowPlane, name: default }` if not present

ClusterWorkflowTemplates are always cluster-scoped — no swap needed.

### 4. Refusing to install vanilla CI workflows in GitOps mode

The script refuses `--kind ClusterWorkflow` on `defaults` mode by default — those four workflows in `all.yaml` write `Workload` CRs directly to the cluster, which Flux reverts. Full reasoning in [`../authoring.md`](../authoring.md) *Vanilla CI workflows aren't GitOps-compatible*.

Override (rarely correct) with `--include-vanilla-ci`. The normal answer is to use §3.

### 5. (If §1 + §3 both chosen) — rewrite `allowedWorkflows[]`

The vanilla CCT YAMLs reference the vanilla CI workflows by name (`paketo-buildpacks-builder` etc.). Replace each CCT's `allowedWorkflows[]` with the GitOps-mode set:

| ComponentType | Recommended `allowedWorkflows[]` |
| --- | --- |
| `service` | `docker-gitops-release`, `google-cloud-buildpacks-gitops-release` |
| `web-application` | `docker-gitops-release`, `google-cloud-buildpacks-gitops-release`, `react-gitops-release` |
| `worker` | `docker-gitops-release`, `google-cloud-buildpacks-gitops-release` |
| `scheduled-task` | `docker-gitops-release`, `google-cloud-buildpacks-gitops-release` |

With `--scope cluster` use `kind: ClusterWorkflow`; with `--scope namespace` use `kind: Workflow`.

### 6. Edit Workflow CR runTemplate parameters

Each GitOps Workflow CR has hardcoded `runTemplate.spec.arguments.parameters` that need per-repo overrides. Open each `platform-shared/workflows/<name>.yaml` and set:

| Parameter | Sample default | Set to |
| --- | --- | --- |
| `gitops-repo-url` | `https://github.com/openchoreo/sample-gitops` | Remote URL of *this* scaffolded repo |
| `gitops-branch` | `main` | This repo's branch |
| `registry-url` | sample-gitops default | Registry the workflow plane can push to and the data plane can pull from |
| `image-name` | `${parameters.projectName}-${parameters.componentName}-image` | Usually leave |
| `image-tag` | `v1` | Usually leave |

The `ClusterSecretStore` name referenced inside the Workflow CR's `ExternalSecret`s is hard-coded to `default` — if the cluster's store has a different name, edit here or rename the store.

### 7. Commit + PR

Canonical flow in [`../authoring.md`](../authoring.md) *Git workflow*. Branch `platform/install-defaults-$(date +%Y%m%d-%H%M%S)`, message `platform: install default project / environments / pipeline / CCTs / Traits / GitOps workflows`.

After merge:

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

## Gotchas

- **`allowedWorkflows[]` is the most common omission.** A CCT still referencing the vanilla CI workflows rejects any Component using `docker-gitops-release` with `WorkflowNotAllowed`.
- **`kind:` mismatch on `allowedWorkflows[]` / `allowedTraits[]`.** A cluster-scoped ComponentType referencing a namespace-scoped Workflow / Trait fails admission. See [`../authoring.md`](../authoring.md) *Cluster ↔ namespace scope* — cross-scope rule.
- **`gitops-repo-url` mismatch** in the Workflow `runTemplate`s. If left at the sample default, every build opens PRs against `openchoreo/sample-gitops` itself. Edit before merging.
- **`registry-url`** must match a registry the workflow plane can push to and the data plane can pull from. Ask the user — the sample default is a placeholder.
- **`ClusterSecretStore` name** in the Workflow CRs' `ExternalSecret`s is hard-coded to `default`. If the cluster's store has a different name, edit the Workflow CR or rename the store.
- **Argo Workflows must be installed on the WorkflowPlane.** Verify: `kubectl get clusterworkflowtemplate`. If the CRD isn't installed, that's an install-side fix.
- **Environments depend on a registered DataPlane.** `ClusterDataPlane/default` must exist before §0 reconciles. Without it, Environments stay `Ready=False`.

## Related

- [`scaffold.md`](./scaffold.md) — scaffolding flow that calls this recipe via *Replace with defaults*
- [`install-flux-and-secrets.md`](./install-flux-and-secrets.md) — Flux install + `git-token` / `gitops-token` / `git-credentials` provisioning
- [`../authoring.md`](../authoring.md) — pin-upstream-fetches rule, scope swap, CI gotcha, repo paths, git workflow
