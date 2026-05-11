# Recipe — Author Environments, DeploymentPipeline, and the default Project

Stand up the standard dev / staging / prod environments, a `DeploymentPipeline` describing how releases promote between them, and (optionally) a default Project for components to land in.

These are all namespace-scoped. Belong under `namespaces/<ns>/platform/infra/` (Environments + DeploymentPipelines) and `namespaces/<ns>/projects/<project>/project.yaml` (Project — note `projects/` is technically developer-side, but the *first* project bootstrap often happens with the PE since they're scaffolding the namespace).

## Preconditions

- At least one `DataPlane` (or `ClusterDataPlane`) registered. `occ clusterdataplane list` should show `default` (or whichever plane the install ships with). Environments need a plane to point at; without one, they reconcile to `Ready=False`.
- The namespace already exists (per `namespaces/<ns>/namespace.yaml`).
- Cluster-scoped platform resources (ClusterComponentType / Trait / Workflow) in place — otherwise the Project + Environments + Pipeline are useless because there's nothing for developers to deploy.

## Source the shapes

```text
https://openchoreo.dev/docs/reference/api/platform/environment.md
https://openchoreo.dev/docs/reference/api/platform/deployment-pipeline.md       (hyphenated!)
https://openchoreo.dev/docs/reference/api/application/project.md
```

Or template from cluster:

```bash
occ environment get development -n default > /tmp/env.yaml
occ deploymentpipeline get default -n default > /tmp/pipeline.yaml
occ project get default -n default > /tmp/project.yaml
```

## Steps

### 1. Environments

Three files (typical), one per env, under `namespaces/<ns>/platform/infra/environments/`:

```yaml
# namespaces/default/platform/infra/environments/development.yaml
# shape: https://openchoreo.dev/docs/reference/api/platform/environment.md (occ v1.0.x)
apiVersion: openchoreo.dev/v1alpha1
kind: Environment
metadata:
  name: development
  namespace: default
spec:
  dataPlaneRef:
    name: default
    kind: ClusterDataPlane               # or DataPlane for namespace-scoped
  isProduction: false
  displayName: Development
  description: Development environment
```

Repeat for `staging.yaml` (`isProduction: false`) and `production.yaml` (`isProduction: true`).

> `spec.dataPlaneRef` is **immutable**. Re-pointing later requires delete + recreate, plus re-binding any `ReleaseBinding`s. Pick the right plane.

### 2. DeploymentPipeline

One file under `namespaces/<ns>/platform/infra/deployment-pipelines/`:

```yaml
# namespaces/default/platform/infra/deployment-pipelines/standard.yaml
# shape: https://openchoreo.dev/docs/reference/api/platform/deployment-pipeline.md (occ v1.0.x)
apiVersion: openchoreo.dev/v1alpha1
kind: DeploymentPipeline
metadata:
  name: standard
  namespace: default
spec:
  promotionPaths:
    - sourceEnvironmentRef:
        name: development
      targetEnvironmentRefs:
        - name: staging
    - sourceEnvironmentRef:
        name: staging
      targetEnvironmentRefs:
        - name: production
```

`promotionPaths[]` is a graph — multiple `targetEnvironmentRefs` from one source forks the promotion; multiple paths can converge.

### 3. Default Project (optional)

Under `namespaces/<ns>/projects/default/project.yaml`. This file straddles the PE / developer boundary — the developer skill owns project authoring, but the first project bootstrap is often a PE setup task.

```yaml
# namespaces/default/projects/default/project.yaml
# shape: https://openchoreo.dev/docs/reference/api/application/project.md (occ v1.0.x)
apiVersion: openchoreo.dev/v1alpha1
kind: Project
metadata:
  name: default
  namespace: default
  annotations:
    openchoreo.dev/display-name: Default
    openchoreo.dev/description: Default project for the default namespace
spec:
  deploymentPipelineRef:
    name: standard
    # kind: DeploymentPipeline           # optional, defaults to DeploymentPipeline
```

> `spec.deploymentPipelineRef` is an **object**, not a plain string (per v1.0.0 schema). `kind` defaults to `DeploymentPipeline` and is safe to omit; include it explicitly when the user wants self-documenting YAML.

### 4. Commit, PR, reconcile

```bash
git checkout -b platform/bootstrap-env-pipeline-$(date +%Y%m%d-%H%M%S)
git add namespaces/<ns>/platform/infra/ namespaces/<ns>/projects/default/
git commit -s -m "platform: bootstrap environments + standard pipeline for <ns>"
git push origin HEAD
gh pr create --fill
```

### 5. Verify

```bash
flux get kustomizations -A
occ environment list -n <ns>             # 3 envs, Ready=True
occ deploymentpipeline get standard -n <ns>
occ project get default -n <ns>          # check deploymentPipelineRef
```

## Variants

### Extra environments (qa, perf, sandbox)

Add the Environment file under `environments/`, then update the pipeline's `promotionPaths[]` to include it:

```yaml
spec:
  promotionPaths:
    - sourceEnvironmentRef: { name: development }
      targetEnvironmentRefs:
        - { name: qa }
    - sourceEnvironmentRef: { name: qa }
      targetEnvironmentRefs:
        - { name: staging }
    # ...
```

### Multiple production environments (regions, fault domains)

Branching paths from `staging`:

```yaml
- sourceEnvironmentRef: { name: staging }
  targetEnvironmentRefs:
    - { name: production-us-east }
    - { name: production-eu-west }
```

### Namespace-scoped DataPlane

For hard tenant isolation (dedicated cluster):

```yaml
spec:
  dataPlaneRef:
    name: tenant-prod-plane
    kind: DataPlane                      # namespace-scoped, not Cluster
  isProduction: true
```

The `DataPlane` itself goes under `namespaces/<ns>/platform/infra/data-planes/<name>.yaml`. Registration of the underlying cluster is install-side, not this skill.

## Gotchas

- **`dataPlaneRef` immutability.** Cannot change once an Environment is created. Plan the topology before authoring.
- **Pipeline names environments, not the other way around.** The pipeline can be authored before or alongside the Environments — controllers reconcile by content, not order. But a pipeline naming an Environment that doesn't exist will sit at `Ready=False` until the env arrives.
- **`Project.spec.deploymentPipelineRef` is an object.** Plain string fails validation since v1.0.0.
- **Project file under `namespaces/<ns>/projects/` is reconciled by the `projects` Kustomization** (which `dependsOn: platform`). The pipeline must already be live for the Project to reconcile cleanly. Co-committing both in one PR is fine — Flux applies them in dependency order.
- **`is_production`** affects no platform behavior directly today, but is the flag downstream automation (promotion gates, alerting) keys on. Set it deliberately.

## Related

- [`scaffold.md`](./scaffold.md) — for a brand-new repo (env / pipeline / project go in early via *Replace with defaults*)
- [`install-defaults.md`](./install-defaults.md) — installs the vanilla project / environments / pipeline from `samples/getting-started/`
- [`../authoring.md`](../authoring.md) — repo paths, llms.txt
- Adding more Projects after the bootstrap is application-side work — out of scope for this skill.
