# Recipe — Onboard a Project and deploy its cell

A Project defines the bounded context; its **cell** (the data-plane namespace + policy) is deployed per environment by a `ProjectReleaseBinding`. **Components can't deploy into an environment until the project's cell exists there**, so this is the first thing to land for a new project. Uses `occ project scaffold` (emits the Project + one binding per pipeline environment), then commit + PR + Flux.

## Prerequisites

1. `occ` configured + logged in (`occ config context list`), and cwd inside a scaffolded GitOps repo (see [`../../SKILL.md`](../../SKILL.md) Step 0).
2. The `(Cluster)ProjectType` the project will use exists on the cluster — PE-authored. Discover with `occ clusterprojecttype list` / `occ projecttype list -n <ns>`. Most installs ship a `default` ClusterProjectType (provisions only the cell namespace); use it unless a richer type is needed.
3. The DeploymentPipeline + its Environments exist (PE-authored). `occ deploymentpipeline get <name> -n <ns>` lists the environments the cell deploys to.

## Steps

### 1. Scaffold the Project + per-env bindings

```bash
occ project scaffold doclet \
  --namespace default --clusterprojecttype default \
  --deployment-pipeline standard \
  -o /tmp/doclet-project.yaml
```

The output is a multi-doc YAML: the `Project` plus one `ProjectReleaseBinding` per pipeline environment. `--projecttype <name>` for a namespace-scoped type; `--no-bindings` to emit only the Project (add bindings later); omit both type flags to default to the `default` ClusterProjectType.

### 2. Split into the repo layout

- `Project` → `namespaces/<ns>/projects/<project>/project.yaml`
- each `ProjectReleaseBinding` → `namespaces/<ns>/projects/<project>/release-bindings/<project>-<env>.yaml`

Fill any placeholders under `Project.spec.parameters` (required params the scaffold left blank). **Leave each binding's `spec.projectRelease` unset** — the Project controller seeds it once with the project's first `ProjectRelease`; that's the deploy model. (Set per-env `spec.environmentConfigs` values here if the ProjectType exposes them.)

### 3. Commit + PR

Branch `release/<project>-onboard-<ts>`, commit message `"release: onboard project <project> + cell bindings"`. Canonical Git flow in [`../authoring.md`](../authoring.md) *Git workflow*. Co-committing the Project + its bindings (+ first Components) in one PR is fine — controllers reconcile by content, not order.

### 4. Verify after merge

Walk the [`../concepts.md`](../concepts.md) *Verification ladder* (Flux source → Kustomization → controllers), then:

```bash
occ project get <project> -n <ns>                       # status.latestRelease.name populated ({project}-{hash})
occ projectreleasebinding get <project>-<env> -n <ns>   # per env
# Synced → NamespaceReady → ResourcesReady → Ready (all True); status.namespace = the cell namespace
```

Once a binding is `Ready`, its environment's cell exists and Components / Resources can deploy into it (see [`onboard-component-byo.md`](./onboard-component-byo.md) / [`onboard-component-source-build.md`](./onboard-component-source-build.md)).

## Promote / roll back the cell

Promotion advances an environment's binding to the release its source environment runs — **bump `spec.projectRelease` in Git** on `release-bindings/<project>-<env>.yaml`, commit, PR (Flux reverts an imperative `occ project deploy` patch on the next reconcile). Rollback is the same operation pointing at an older `ProjectRelease`. Read the source pin with `occ projectreleasebinding get <project>-<source-env>`; list releases with `occ projectrelease list -n <ns>`. Full pattern in [`promote.md`](./promote.md).

## Gotchas

- **`Project.spec.type` is required and immutable.** Re-targeting a project to a different ProjectType means delete + recreate the Project.
- **`ProjectRelease` is controller-cut and never in Git** — commit the inputs (`Project` + `ProjectReleaseBinding`s); the controller produces the release and seeds the pins.
- **Leave `spec.projectRelease` empty on first commit.** A hard-coded pin to a not-yet-existing release makes the binding `Synced=False, Reason=ProjectReleaseNotFound`. Empty → seeded once, then you promote explicitly.
- **`owner.projectName` and `environment` are immutable on a binding.** To re-target, delete + recreate the binding file.

## Related

- [`../concepts.md`](../concepts.md) *Project*, *Resource hierarchy*, *Verification ladder*
- [`../authoring.md`](../authoring.md) *`occ project scaffold`*, *Repo paths*, *Git workflow*
- [`promote.md`](./promote.md) — advancing the pin across environments
- [`onboard-component-byo.md`](./onboard-component-byo.md) / [`onboard-component-source-build.md`](./onboard-component-source-build.md) — deploy components into the cell
