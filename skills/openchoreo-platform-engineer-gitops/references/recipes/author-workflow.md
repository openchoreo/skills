# Recipe — Author a (Cluster)Workflow via Git

Define a build template (or generic automation). Backed by Argo Workflows: the OpenChoreo `Workflow` CR carries the parameter schema and an inline `runTemplate` (Argo `Workflow`), usually referencing a `ClusterWorkflowTemplate` for step logic.

For installing the standard GitOps build-and-release bundle, see [`install-defaults.md`](./install-defaults.md). This recipe is for authoring a new Workflow from scratch.

> **The four vanilla CI workflows aren't GitOps-compatible.** Build a Workflow that ends in `git-commit-push-pr` (writes to GitOps repo), not `generate-workload-cr` (writes to cluster API). See [`../authoring.md`](../authoring.md) *Vanilla CI workflows aren't GitOps-compatible*.

## Scope decision

| Scope | When | Path |
| --- | --- | --- |
| `ClusterWorkflow` (default) | Available to every namespace. | `platform-shared/workflows/<name>.yaml` |
| `Workflow` (namespace-scoped) | Tenant-specific, or consumes namespace-scoped secrets. | `namespaces/<ns>/platform/workflows/<name>.yaml` |

**Scope rule.** `ClusterComponentType.allowedWorkflows` may only reference `ClusterWorkflow`. Namespace-scoped `ComponentType` may reference either.

## Two kinds of Workflow

- **Component-bound build workflow** — triggered by a Component with `spec.workflow`. Standard parameters: `componentName`, `projectName`, `repository.*`, `docker.*` / `buildpacks.*`. Produces an image + (GitOps mode) a PR on the GitOps repo.
- **Generic / automation workflow** — triggered via standalone `WorkflowRun`. Promotion (`bulk-gitops-release`), migrations, scheduled tasks.

Same CRD shape; what differs is the parameter schema and what `runTemplate` does.

## Steps

### 1. Source the shape

- **Full schema** — `./scripts/fetch-page.sh --exact --title "ClusterWorkflow"` (or `"Workflow"`).
- **GitOps reference** — the four GitOps workflows in `sample-gitops` are the canonical examples. URLs in [`../authoring.md`](../authoring.md). Their paired Argo `ClusterWorkflowTemplate`s sit under `platform-shared/cluster-workflow-templates/argo/<name>-template.yaml` in `sample-gitops`.

Don't copy from `samples/getting-started/ci-workflows/` — those are the vanilla CI workflows and aren't GitOps-compatible.

### 2. Compose

Key pieces:

- **`parameters.openAPIV3Schema`** — what the `WorkflowRun` carries.
- **`runTemplate`** — the Argo Workflow that materialises per run. Templating context differs from ComponentType — see [`../cel.md`](../cel.md) §5 *Workflow-only variables*. Available: `metadata.workflowRunName`, `metadata.namespace`, `metadata.namespaceName`, `parameters.*`, `workflowplane.secretStore`, `externalRefs[id]`.
- **`resources[]`** — auxiliary resources per run (usually `ExternalSecret`s for git tokens).

Skeleton (generic workflow):

```yaml
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
      serviceAccountName: workflow-sa
      workflowTemplateRef:
        clusterScope: true
        name: bulk-gitops-release         # Argo ClusterWorkflowTemplate
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

Component-bound build-workflow shape adds: `componentName` / `projectName` as required parameters, a `workloadDescriptorPath` parameter, and hard-coded `gitops-repo-url` / `registry-url` / `image-name` / `image-tag` in `runTemplate.spec.arguments.parameters` (PE-controlled). See `sample-gitops/namespaces/default/platform/workflows/docker-with-gitops-release.yaml` for the canonical example.

### 3. Argo `ClusterWorkflowTemplate`

If `runTemplate.spec.workflowTemplateRef` references one, the template must exist on the workflow plane. Options:

- Pull from `sample-gitops/platform-shared/cluster-workflow-templates/argo/` and commit under `platform-shared/cluster-workflow-templates/argo/<name>.yaml`. Flux applies via the `platform-shared` Kustomization.
- Inline the steps in `runTemplate.spec.templates[]` — fine for small workflows; doesn't compose across Workflow CRs.

### 4. Allow-list the workflow

Edit the `(Cluster)ComponentType`s that should permit it, add to `spec.allowedWorkflows[]`, commit, PR.

### 5. Commit + verify

Branch `platform/workflow-<name>-<ts>`, message `"platform: add <ClusterWorkflow|Workflow> <name>"`. Canonical flow in [`../authoring.md`](../authoring.md) *Git workflow*. After merge:

```bash
flux get kustomizations -A
occ clusterworkflow get <name>             # or occ workflow get <name> -n <ns>
```

Smoke-test:

```bash
occ component workflow run <component> -n <ns> -p <project>
occ workflowrun list -n <ns>
occ workflowrun get <run-name> -n <ns>
occ workflowrun logs <run-name> -n <ns> -f         # live + archived
```

Use `occ workflowrun list/get/logs` — don't reach for `kubectl get workflow.argoproj.io -n workflows-<ns>` or `kubectl logs -n workflows-<ns> <pod>`. The `occ` wrappers cover both without needing to know the workflow-plane namespace.

## Gotchas

- **Workflow CR validation is permissive.** Most errors surface at WorkflowRun time. Inspect with `occ workflowrun get <run-name>`.
- **Hard-coded `runTemplate.spec.arguments.parameters`** (`gitops-repo-url`, `registry-url`, `image-tag`) are PE-controlled. Editing the Workflow CR changes them for all subsequent runs.
- **`workflowplane.secretStore`** is the CEL accessor for the `ClusterSecretStore` on the referenced WorkflowPlane. Use this instead of hardcoding.
- **Build workflows need git tokens** — `git-token` (source clone), `gitops-token` (GitOps repo writes). See [`install-flux-and-secrets.md`](./install-flux-and-secrets.md).
- **`workflowTemplateRef.clusterScope: true`** required to reach a `ClusterWorkflowTemplate`. Without it the lookup is in the workflow plane's namespace and fails.
- **The build's `generate-workload` step is opinionated** — names the Workload CR `<component>-workload` regardless of the descriptor's `metadata.name`. Without a `workload.yaml` at `<appPath>`, the generated Workload carries only `container.image`.
