# Recipe — Author Environments, DeploymentPipeline, and the default Project

Stand up dev / staging / prod environments, a `DeploymentPipeline` describing the promotion graph, and (optionally) a default Project. All namespace-scoped.

## Preconditions

- At least one `DataPlane` / `ClusterDataPlane` registered. Environments without one reconcile to `Ready=False`. Check: `occ clusterdataplane list` and, for namespace-scoped planes, `occ dataplane list -n <ns>`.
- The namespace already exists (`namespaces/<ns>/namespace.yaml`).
- Cluster-scoped platform resources (ClusterComponentType / Trait / Workflow) in place — otherwise the bootstrap is useless because there's nothing for developers to deploy.

## Source the shape

```bash
./scripts/fetch-page.sh --exact --title "Environment"
./scripts/fetch-page.sh --exact --title "DeploymentPipeline"
./scripts/fetch-page.sh --exact --title "Project"
```

## Steps

### 1. Environments

One file per env, under `namespaces/<ns>/platform/infra/environments/`:

```yaml
apiVersion: openchoreo.dev/v1alpha1
kind: Environment
metadata:
  name: development
  namespace: default
spec:
  dataPlaneRef:
    name: default
    kind: ClusterDataPlane             # or DataPlane for namespace-scoped
  isProduction: false
  displayName: Development
  description: Development environment
```

Repeat for `staging.yaml` and `production.yaml` (`isProduction: true` on prod).

> `spec.dataPlaneRef` is **immutable**. Re-pointing means delete + recreate + re-bind every ReleaseBinding. Pick deliberately.

### 2. DeploymentPipeline

One file under `namespaces/<ns>/platform/infra/deployment-pipelines/`:

```yaml
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

`promotionPaths[]` is a graph — multiple `targetEnvironmentRefs` from one source forks; multiple paths can converge.

### 3. Default Project (optional)

Under `namespaces/<ns>/projects/<project>/project.yaml`. Straddles the PE / developer boundary — Project authoring is developer-side, but the *first* bootstrap is often a PE task.

```yaml
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
    # kind: DeploymentPipeline         # optional; defaults to DeploymentPipeline
```

`spec.deploymentPipelineRef` is an **object**, not a plain string (since v1.0.0).

### 4. Commit + PR

Branch `platform/bootstrap-env-pipeline-<ts>`, paths `namespaces/<ns>/platform/infra/` + `namespaces/<ns>/projects/<project>/`, message `"platform: bootstrap environments + standard pipeline for <ns>"`. Canonical sequence in [`../authoring.md`](../authoring.md) *Git workflow*.

### 5. Verify

```bash
flux get kustomizations -A
occ environment list -n <ns>
occ deploymentpipeline get standard -n <ns>
occ project get <project> -n <ns>
```

## Variants

### Extra environments (qa, perf, sandbox)

Add an Environment file, then update the pipeline:

```yaml
promotionPaths:
  - sourceEnvironmentRef: { name: development }
    targetEnvironmentRefs:
      - { name: qa }
  - sourceEnvironmentRef: { name: qa }
    targetEnvironmentRefs:
      - { name: staging }
```

### Multiple production environments (regions, fault domains)

```yaml
- sourceEnvironmentRef: { name: staging }
  targetEnvironmentRefs:
    - { name: production-us-east }
    - { name: production-eu-west }
```

### Namespace-scoped DataPlane

For hard tenant isolation:

```yaml
spec:
  dataPlaneRef:
    name: tenant-prod-plane
    kind: DataPlane
  isProduction: true
```

The `DataPlane` itself goes under `namespaces/<ns>/platform/infra/data-planes/<name>.yaml`. Registering the underlying cluster is install-side, not this skill.

## Gotchas

- **`dataPlaneRef` is immutable.** Plan topology before authoring.
- **Pipeline can name an Environment that doesn't exist yet** — controllers reconcile by content, not order. Co-committing in one PR is fine.
- **`Project.spec.deploymentPipelineRef` is an object.** Plain string fails validation.
- **`Project` reconciles via the `projects` Kustomization** (which `dependsOn: platform`). Pipeline must be live before the Project goes `Ready=True`; co-committing works since dependency order is enforced upstream.
- **`isProduction` affects no platform behavior directly today** but is the flag downstream automation (gates, alerting) keys on. Set deliberately.
