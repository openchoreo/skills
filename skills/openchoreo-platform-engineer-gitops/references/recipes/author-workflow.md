# Recipe — Author a (Cluster)Workflow via Git

Define a build template (or generic automation) that Components can opt into. Backed by Argo Workflows: the OpenChoreo `Workflow` CR carries the parameter schema and an inline `runTemplate` (Argo `Workflow`), usually referencing a `ClusterWorkflowTemplate` for the step logic.

For installing the standard GitOps build-and-release bundle (`docker-gitops-release` / `google-cloud-buildpacks-gitops-release` / `react-gitops-release` / `bulk-gitops-release`), see [`install-defaults.md`](./install-defaults.md). This recipe is for authoring a new Workflow from scratch or modifying an existing one.

> **Vanilla CI workflows (`dockerfile-builder` etc.) aren't GitOps-compatible** — they write the `Workload` directly to the cluster API server, which Flux reverts. Build a new Workflow that follows the GitOps shape (build → push → clone gitops repo → generate manifests → open PR) instead. See [`../authoring.md`](../authoring.md) *Vanilla CI workflows aren't GitOps-compatible*.

## Scope decision

| Scope                   | When                                                                          | File path                                                  |
| ----------------------- | ----------------------------------------------------------------------------- | ---------------------------------------------------------- |
| `ClusterWorkflow` (default) | Builder available to every namespace (e.g. `dockerfile-builder`).         | `platform-shared/workflows/<name>.yaml`                    |
| `Workflow` (namespace-scoped) | Tenant-specific builder or one that consumes namespace-scoped secrets.  | `namespaces/<ns>/platform/workflows/<name>.yaml`           |

**Scope rule.** A `ClusterComponentType`'s `allowedWorkflows` may only reference `ClusterWorkflow`. Namespace-scoped `ComponentType` may reference either.

## Two kinds of Workflow

**Component-bound build workflow** — invoked when a Component with `spec.workflow` triggers a `WorkflowRun`. Standard parameters: `componentName`, `projectName`, `repository.*`, `docker.*` or `buildpacks.*`. The build produces an image and (optionally) a Workload CR.

**Generic / automation workflow** — invoked via standalone `WorkflowRun` (no Component binding). Used for promotion (`bulk-gitops-release`), migrations, scheduled tasks, etc.

The CRD shape is the same; what differs is the parameter schema and what the `runTemplate` does.

## Steps

### 1. Source the shape

Pick one per the shape-lookup decision table in [`../authoring.md`](../authoring.md):

- **Live cluster** — `occ clusterworkflow get <name>` or `occ workflow get <name> -n <ns>`. Strip status / managed fields.
- **GitOps reference shape** — the four GitOps workflows in `sample-gitops` are the canonical GitOps examples. WebFetch from `https://raw.githubusercontent.com/openchoreo/sample-gitops/main/namespaces/default/platform/workflows/<name>.yaml`. Their paired `ClusterWorkflowTemplate`s are at `https://raw.githubusercontent.com/openchoreo/sample-gitops/main/platform-shared/cluster-workflow-templates/argo/<name>-template.yaml`.
- **API reference** — `https://openchoreo.dev/docs/reference/api/platform/clusterworkflow.md` (cluster) or `.../workflow.md` (namespace).

> **Don't copy the vanilla CI workflows** from `samples/getting-started/ci-workflows/` — they write Workload to the cluster directly. Use the GitOps shapes from `sample-gitops` as your reference.

### 2. Compose the spec

Three key pieces:

- **`parameters.openAPIV3Schema`** — what the WorkflowRun carries. Strongly typed; `oneOf` / `anyOf` constraints supported.
- **`runTemplate`** — the rendered Argo Workflow. Templating contexts are different from ComponentType templates — see [`../cel.md`](../cel.md) §5 *Workflow-only variables*. Has access to `metadata.workflowRunName`, `metadata.namespace` (enforced workflow plane namespace), `parameters.*`, `workflowplane.secretStore`, `externalRefs[id]`.
- **`resources[]`** — auxiliary K8s resources spun up per run (often `ExternalSecret`s for git tokens). Same shape as ComponentType resources but in the workflow plane's namespace.

Skeleton for a generic workflow (no component binding):

```yaml
# shape: https://openchoreo.dev/docs/reference/api/platform/workflow.md (occ v1.0.x)
apiVersion: openchoreo.dev/v1alpha1
kind: Workflow
metadata:
  name: bulk-gitops-release
  namespace: <ns>
spec:
  parameters:
    openAPIV3Schema:
      type: object
      required: [scope, gitops]
      properties:
        scope:
          type: object
          required: [projectName]
          properties:
            all:         { type: boolean, default: false }
            projectName: { type: string }
        gitops:
          type: object
          required: [repositoryUrl, deploymentPipeline]
          properties:
            repositoryUrl:      { type: string }
            branch:             { type: string, default: main }
            targetEnvironment:  { type: string, default: development }
            deploymentPipeline: { type: string }
  runTemplate:
    apiVersion: argoproj.io/v1alpha1
    kind: Workflow
    metadata:
      name: ${metadata.workflowRunName}
      namespace: ${metadata.namespace}
    spec:
      arguments:
        parameters:
          - name: namespace-name
            value: ${metadata.namespaceName}
          - name: scope-all
            value: ${parameters.scope.all}
          # …
      serviceAccountName: workflow-sa
      workflowTemplateRef:
        clusterScope: true
        name: bulk-gitops-release         # references an Argo ClusterWorkflowTemplate
  resources:
    - id: gitops-git-secret
      template:
        apiVersion: external-secrets.io/v1
        kind: ExternalSecret
        metadata:
          name: ${metadata.workflowRunName}-gitops-git-secret
          namespace: ${metadata.namespace}
        spec:
          refreshInterval: 15s
          secretStoreRef: { name: default, kind: ClusterSecretStore }
          target: { name: ${metadata.workflowRunName}-gitops-git-secret, creationPolicy: Owner }
          data: [{ secretKey: git-token, remoteRef: { key: gitops-token, property: git-token } }]
```

The component-bound build-workflow shape adds:

- `componentName` and `projectName` as required parameters.
- A `workloadDescriptorPath` parameter so the `generate-workload` step can find `workload.yaml`.
- Hard-coded values in `runTemplate.spec.arguments.parameters` for `gitops-repo-url`, `registry-url`, `image-name`, `image-tag` (PE-controlled, not developer-passed).

See `sample-gitops/namespaces/default/platform/workflows/docker-with-gitops-release.yaml` for the canonical example.

### 3. Argo `ClusterWorkflowTemplate` — when needed

If `runTemplate.spec.workflowTemplateRef` references a `ClusterWorkflowTemplate`, that template must exist on the workflow plane. Two options:

- Pull the template from `sample-gitops/platform-shared/cluster-workflow-templates/argo/` and commit it under `platform-shared/cluster-workflow-templates/argo/<name>.yaml` in this repo. Flux applies it via the `platform-shared` Kustomization.
- Define the steps inline in `runTemplate.spec.templates[]` (Argo's `templates` array) — fine for small workflows, but step logic doesn't compose across Workflow CRs.

The Argo `ClusterWorkflowTemplate` shape is upstream Argo, not OpenChoreo — its docs are at <https://argo-workflows.readthedocs.io/en/latest/cluster-workflow-templates/>.

### 4. Allow-list the workflow

`(Cluster)ComponentType.allowedWorkflows[]` gates which workflows developers may attach. After authoring a new workflow, edit the relevant `(Cluster)ComponentType`s and add it. Commit, PR, reconcile.

### 5. Commit, PR, reconcile

```bash
git checkout -b platform/workflow-<name>-$(date +%Y%m%d-%H%M%S)
git add <file>
git commit -s -m "platform: add <ClusterWorkflow|Workflow> <name>"
git push origin HEAD
gh pr create --fill
```

### 6. Verify

```bash
flux get kustomizations -A
occ clusterworkflow get <name>             # or occ workflow get <name> -n <ns>
```

Smoke-test by triggering a WorkflowRun (developer side):

```bash
occ component workflow run <component> -n <ns> -p <project>
# or apply a standalone WorkflowRun manifest
occ workflowrun list -n <ns>
occ workflowrun get <run-name> -n <ns>
```

## Gotchas

- **Workflow CR validation is permissive.** Most errors surface in Argo at WorkflowRun time. Inspect with `occ workflowrun get <run-name>` and look at the Argo workflow's `status` (or use the Argo UI if available).
- **Hard-coded values in `runTemplate.spec.arguments.parameters`** (`gitops-repo-url`, `registry-url`, `image-tag`) are PE-controlled — developers don't pass them. Editing the Workflow CR changes them for all subsequent runs. Treat as semi-static config.
- **`workflowplane.secretStore`** is the CEL accessor for the `ClusterSecretStore` name on the referenced WorkflowPlane. Use this instead of hard-coding.
- **Build workflows need git tokens.** Standard convention: `git-token` for source repos, `gitops-token` for GitOps repo writes. See [`install-flux-and-secrets.md`](./install-flux-and-secrets.md) for provisioning.
- **`workflowTemplateRef.clusterScope: true`** — for `ClusterWorkflowTemplate` reference. Without it, the lookup is in the workflow plane's namespace, which fails.
- **The build's `generate-workload` step is opinionated.** It produces a Workload CR named `{component}-workload` (overriding any `metadata.name` from the descriptor). And the auto-generated Workload only carries `container.image` unless `workload.yaml` exists at the descriptor path.

## Related

- [`install-defaults.md`](./install-defaults.md) — install the standard GitOps build-and-release bundle
- [`author-componenttype.md`](./author-componenttype.md) — `allowedWorkflows` needs updating to permit a new workflow
- [`../cel.md`](../cel.md) — Workflow-only CEL context (`metadata.workflowRunName`, `parameters`, `externalRefs`, `workflowplane.secretStore`)
- Argo Workflows docs — <https://argo-workflows.readthedocs.io/>
