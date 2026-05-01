# Workflows

This file is the authoring reference for **Workflows** and **ClusterWorkflows** — the platform-engineer-defined templates that power CI builds and standalone automation in OpenChoreo. Backed by [Argo Workflows](https://argo-workflows.readthedocs.io/).

For CEL syntax used in `runTemplate` and `resources`, see [`cel.md`](./cel.md). For ComponentType `allowedWorkflows` governance, see also [`component-types-and-traits.md`](./component-types-and-traits.md). The full MCP tool list is discovered at runtime via the control-plane MCP server.

**Tool surface:**

- **`Workflow` / `ClusterWorkflow` (control plane CRDs)** — MCP-first. `create_workflow` / `create_cluster_workflow` / `update_*` / `delete_*` all exist. The full `spec` body is passed to create / update (including `runTemplate` — the inline Argo Workflow). `update_*` is full-spec replacement; read first via `get_*`. `kubectl apply -f` is a fine fallback for big edits to `runTemplate` CEL where the diff is easier to manage as YAML.
- **Argo `ClusterWorkflowTemplate`s (workflow plane)** — kubectl-only. These are upstream Argo CRDs, not OpenChoreo CRDs, and have no MCP path. Apply with `kubectl apply -f` against the workflow-plane cluster.
- **`WorkflowRun` (control plane)** — created via `trigger_workflow_run` (component-bound) or `create_workflow_run` (standalone) MCP tools, or via Git webhook for auto-build, or hand-applied with `kubectl apply -f` for ad-hoc cases.

Contents:

1. Concepts — resources and the multi-plane architecture
2. Generic vs CI workflows
3. Authoring — the 3-step process
4. Schema syntax (`openAPIV3Schema`)
5. ExternalRefs
6. Resources (auxiliary CRs)
7. CI workflow specifics — labels, vendor extensions, `allowedWorkflows` governance
8. WorkflowRun validation
9. TTL and cleanup
10. Verification — MCP and `kubectl` flows

---

## 1. Concepts

OpenChoreo runs every automation task — CI builds, infra provisioning, ETL, custom Docker builds — through the same `Workflow` and `WorkflowRun` resources. The execution engine is Argo Workflows.

### Resources at a glance

| Resource | Where it lives | Authored by | Purpose |
|---|---|---|---|
| **`Workflow` / `ClusterWorkflow`** | Control plane | Platform engineer | Template — schema + embedded Argo Workflow |
| **`WorkflowRun`** | Control plane | Developer / webhook / MCP / `kubectl apply` | Single execution instance referencing a Workflow |
| **Argo `ClusterWorkflowTemplate`** | Workflow plane | Platform engineer | One reusable step (clone, build, push, etc.) |
| **Argo `Workflow`** | Workflow plane | Auto-generated | Rendered from `runTemplate` at run time — you never write this directly |

### Multi-plane architecture

- **Control plane** — hosts `Workflow` and `WorkflowRun` CRs, orchestrates execution.
- **Workflow plane** — runs Argo Workflows from `ClusterWorkflowTemplate`s, performs compute-heavy work (builds, terraform, etc.).
- **Communication** — control plane controller talks to the workflow plane via a websocket connection.

In single-cluster setups, both planes run in the same cluster.

### `WorkflowRun` is imperative

> **Don't put `WorkflowRun` in GitOps repos.** It triggers an action rather than declaring desired state. Create runs through Git webhooks, the UI, MCP (`trigger_workflow_run` / `create_workflow_run`), or `kubectl apply`.
>
> The `workflow` reference (`spec.workflow.kind` and `name`) is **immutable** on a `WorkflowRun` once created — you cannot change which workflow a run targets after it exists. Create a new run for a different workflow.

### `runTemplate` vs ClusterWorkflowTemplates

A `ClusterWorkflowTemplate` defines **one step**. The Workflow CR's `runTemplate` is an inline Argo Workflow that **composes multiple CWTs into a pipeline** via per-step `templateRef`:

```yaml
runTemplate:
  apiVersion: argoproj.io/v1alpha1
  kind: Workflow
  spec:
    entrypoint: pipeline
    templates:
      - name: pipeline
        steps:
          - - name: checkout-source
              templateRef:
                name: checkout-source     # CWT name
                template: checkout
                clusterScope: true
          - - name: build-image
              templateRef:
                name: docker
                template: build-image
                clusterScope: true
```

Use ClusterWorkflowTemplates for every step — that way logic for "how we build a Docker image" lives in one place and is reused by every Workflow that references it.

---

## 2. Generic vs CI workflows

### Generic workflows

Standalone automation not tied to any component:

- Infrastructure provisioning (Terraform, Pulumi)
- Data pipelines / ETL
- End-to-end test suites
- Package publishing (npm, PyPI, Maven)
- Custom Docker builds

Plain `Workflow` CR. No special labels.

### CI workflows (component workflows)

Workflows used by Components for source builds. A Workflow is component-capable when **all three** of these are true:

1. It carries the label `openchoreo.dev/workflow-type: "component"` — required for UI/CLI categorization.
2. A `Component` references it via `Component.spec.workflow.name`.
3. It is listed in the ComponentType's `spec.allowedWorkflows`.

There is no separate CRD — a CI workflow is just a Workflow that satisfies these three.

CI workflows additionally support:

- Auto-builds triggered by Git webhooks
- UI integration for build management
- Workload generation from build output

See §7 for CI-specific labels, vendor extensions, and governance.

---

## 3. Authoring — the 3-step process

To create a custom Workflow:

1. **Create the `ClusterWorkflowTemplate`(s)** in the workflow plane — define the actual step logic.
2. **Design the Argo Workflow structure** that references those CWTs — the pipeline shape and parameters.
3. **Create the `Workflow` (or `ClusterWorkflow`) CR** in the control plane — schema + embedded `runTemplate`.

### Step 1 — `ClusterWorkflowTemplate`

A CWT defines **one reusable step**. Inputs and outputs use Argo's parameter syntax:

- `{{inputs.parameters.git-revision}}` — input passed to this template by another step.
- `{{workflow.parameters.component-name}}` — global Argo Workflow parameter.
- `{{steps.checkout-source.outputs.parameters.git-revision}}` — output from a previous step.

Example — a Docker build step:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ClusterWorkflowTemplate
metadata:
  name: docker
spec:
  templates:
    - name: build-image
      inputs:
        parameters:
          - name: git-revision
      container:
        image: ghcr.io/openchoreo/podman-runner:v1.0
        command: [sh, -c]
        args:
          - |
            set -e
            WORKDIR="/mnt/vol/source"
            IMAGE="{{workflow.parameters.image-name}}:{{workflow.parameters.image-tag}}-{{inputs.parameters.git-revision}}"
            DOCKER_CONTEXT="{{workflow.parameters.docker-context}}"
            DOCKERFILE_PATH="{{workflow.parameters.dockerfile-path}}"

            mkdir -p /etc/containers
            cat > /etc/containers/storage.conf <<EOF
            [storage]
            driver = "overlay"
            runroot = "/run/containers/storage"
            graphroot = "/var/lib/containers/storage"
            [storage.options.overlay]
            mount_program = "/usr/bin/fuse-overlayfs"
            EOF

            podman build -t $IMAGE -f $WORKDIR/$DOCKERFILE_PATH $WORKDIR/$DOCKER_CONTEXT
            podman save -o /mnt/vol/app-image.tar $IMAGE
        securityContext:
          privileged: true
        volumeMounts:
          - mountPath: /mnt/vol
            name: workspace
```

### Step 2 — Argo Workflow shape

Decide the pipeline structure before writing the CR. Categorize each parameter into one of three types:

| Type | Source | Example |
|---|---|---|
| **Hard-coded** | Platform engineer locks the value | `trivy-scan: "true"`, `registry: "ghcr.io"` |
| **Developer-provided** | Filled in via `WorkflowRun.spec.workflow.parameters` | `repository.url`, `branch`, `timeout` |
| **System-generated** | Injected at runtime by OpenChoreo | `${metadata.workflowRunName}`, `${metadata.namespaceName}`, `${metadata.namespace}`, `${externalRefs[...].spec.*}` |

Hard-coded parameters live in the `runTemplate`. Developer-provided parameters go in the schema (§4). System-generated parameters come from CEL context (`metadata.*`, `externalRefs.*`, `workflowplane.*`).

Skeleton (will be embedded in the Workflow CR):

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Workflow
metadata:
  name: ${metadata.workflowRunName}
  namespace: ${metadata.namespace}
spec:
  serviceAccountName: workflow-sa            # platform-managed; don't change
  entrypoint: pipeline
  arguments:
    parameters:
      - name: component-name
        value: ${metadata.labels['openchoreo.dev/component']}
      - name: project-name
        value: ${metadata.labels['openchoreo.dev/project']}
      - name: image-name
        value: ${metadata.namespaceName}-${metadata.workflowRunName}
      - name: repo-url
        value: ${parameters.repository.url}
      - name: branch
        value: ${parameters.repository.revision.branch}
      - name: trivy-scan
        value: "true"                        # hard-coded
  templates:
    - name: pipeline
      steps:
        - - name: checkout-source
            templateRef:
              name: checkout-source
              template: checkout
              clusterScope: true
        - - name: build-image
            templateRef:
              name: docker
              template: build-image
              clusterScope: true
            arguments:
              parameters:
                - name: git-revision
                  value: '{{steps.checkout-source.outputs.parameters.git-revision}}'
        - - name: publish-image
            templateRef:
              name: publish-image
              template: publish-image
              clusterScope: true
            arguments:
              parameters:
                - name: git-revision
                  value: '{{steps.checkout-source.outputs.parameters.git-revision}}'
  volumeClaimTemplates:
    - metadata:
        name: workspace
      spec:
        accessModes: [ReadWriteOnce]
        resources:
          requests:
            storage: 2Gi
```

### Step 3 — the `Workflow` CR

The CR has three notable fields:

- **`parameters.openAPIV3Schema`** — what developers can configure (§4).
- **`runTemplate`** — the Argo Workflow shape from Step 2, with CEL expressions in place of literal values.
- **`resources`** (optional) — auxiliary Kubernetes resources to create alongside the run (§6).
- **`externalRefs`** (optional) — references to external CRs resolved at run time (§5).
- **`ttlAfterCompletion`** (optional) — how long to keep finished runs (§9).

Full skeleton:

```yaml
apiVersion: openchoreo.dev/v1alpha1
kind: Workflow                              # or ClusterWorkflow
metadata:
  name: dockerfile-builder
  namespace: default                        # omit for ClusterWorkflow
  labels:
    openchoreo.dev/workflow-type: "component"  # only for CI workflows; see §7
spec:
  ttlAfterCompletion: "1d"

  parameters:
    openAPIV3Schema: { ... }                # see §4

  externalRefs:
    - id: git-secret-reference              # see §5
      apiVersion: openchoreo.dev/v1alpha1
      kind: SecretReference
      name: ${parameters.repository.secretRef}

  runTemplate: { ... }                      # the Argo Workflow from Step 2

  resources:                                # see §6
    - id: git-secret
      template: { ... }
```

---

## 4. Schema syntax (`openAPIV3Schema`)

Workflow `parameters` use OpenAPI v3 JSON Schema. Same shape as ComponentType / Trait schemas (see `component-types-and-traits.md` §4) — but with one important difference.

> **Required-by-default rule differs.** In Workflow schemas, fields are **optional by default** unless listed under `required`. In ComponentType / Trait schemas, fields are required by default unless they have a `default`.

Use `required: [field, ...]` at the object level to mark mandatory fields, and `default` for optional ones with a fallback:

```yaml
parameters:
  openAPIV3Schema:
    type: object
    required:
      - repository
    properties:
      repository:
        type: object
        required:
          - url
        properties:
          url:
            type: string
            description: "Git repository URL"
          revision:
            type: object
            default: {}
            properties:
              branch:
                type: string
                default: main
              commit:
                type: string
                default: ""
          appPath:
            type: string
            default: "."
      timeout:
        type: string
        default: "30m"
      trivyScan:
        type: boolean
        default: true
```

When an object has `default: {}`, all its nested defaults apply automatically, so omitting it produces the fully-defaulted object.

Standard JSON Schema constraints (`minimum`, `maximum`, `minLength`, `maxLength`, `pattern`, `enum`, `minItems`, `maxItems`, `uniqueItems`, etc.) are supported. See `component-types-and-traits.md` §4 for the full constraint catalogue — same syntax.

### Accessing parameters in `runTemplate`

Schema-defined parameters are available via CEL:

```yaml
runTemplate:
  spec:
    arguments:
      parameters:
        - name: git-repo
          value: ${parameters.repository.url}
        - name: branch
          value: ${parameters.repository.revision.branch}
        - name: timeout
          value: ${parameters.timeout}
```

Workflow-only context variables (`metadata.workflowRunName`, `metadata.namespaceName`, `metadata.namespace`, `workflowplane.secretStore`, `externalRefs[...]`) are listed in `cel.md` §5. Note: `metadata.namespaceName` is the user-facing namespace (e.g. `default`); `metadata.namespace` is the enforced workflow-plane execution namespace (e.g. `workflows-default`) — they are not interchangeable.

---

## 5. ExternalRefs

`externalRefs` lets a Workflow resolve external CRs (currently `SecretReference`) **before** the Argo Workflow is instantiated, and exposes them via the `externalRefs[<id>]` CEL variable.

Use cases:

- Resolve credential secrets dynamically (Git auth, registry push)
- Conditionally create resources only when an external ref is provided
- Reuse credential patterns across runs

### Declaration

```yaml
externalRefs:
  - id: git-secret-reference                # unique key for this reference
    apiVersion: openchoreo.dev/v1alpha1
    kind: SecretReference                   # only SecretReference is supported today
    name: ${parameters.repository.secretRef}  # may be parameterized
```

### Behavior

- Each entry needs a unique `id`.
- `name` may be an expression — resolved against `parameters` and `metadata`.
- If `name` evaluates to an empty string, the reference is silently skipped — no error. Pair with `includeWhen` on resources that depend on it.

### Access

```yaml
# Whole spec
${externalRefs['git-secret-reference'].spec}

# Specific field
${externalRefs['git-secret-reference'].spec.template.type}

# Iterate over data array
${externalRefs['git-secret-reference'].spec.data}

# Conditional logic
${has(externalRefs['git-secret-reference']) && externalRefs['git-secret-reference'].spec.enabled}
```

### Worked example

```yaml
externalRefs:
  - id: git-secret-reference
    apiVersion: openchoreo.dev/v1alpha1
    kind: SecretReference
    name: ${parameters.repository.secretRef}

resources:
  - id: git-credentials
    includeWhen: ${has(parameters.repository.secretRef) && parameters.repository.secretRef != ""}
    template:
      apiVersion: external-secrets.io/v1
      kind: ExternalSecret
      metadata:
        name: ${metadata.workflowRunName}-git-secret
        namespace: ${metadata.namespace}
      spec:
        refreshInterval: 15s
        secretStoreRef:
          kind: ClusterSecretStore
          name: ${workflowplane.secretStore}
        target:
          name: ${metadata.workflowRunName}-git-secret
          creationPolicy: Owner
          template:
            type: ${externalRefs['git-secret-reference'].spec.template.type}
        data: |
          ${externalRefs['git-secret-reference'].spec.data.map(secret, {
            "secretKey": secret.secretKey,
            "remoteRef": {
              "key": secret.remoteRef.key,
              "property": has(secret.remoteRef.property) ? secret.remoteRef.property : oc_omit()
            }
          })}
```

---

## 6. Resources

Auxiliary Kubernetes resources to create alongside the workflow run, in the workflow-plane namespace. Same `template` / `includeWhen` / `forEach` / `var` semantics as ComponentType `resources` (see `component-types-and-traits.md` §2).

Common pattern — `ExternalSecret` for credentials:

```yaml
resources:
  - id: registry-push-secret
    template:
      apiVersion: external-secrets.io/v1
      kind: ExternalSecret
      metadata:
        name: ${metadata.workflowRunName}-registry-push
        namespace: ${metadata.namespace}
      spec:
        refreshInterval: 15s
        secretStoreRef:
          kind: ClusterSecretStore
          name: ${workflowplane.secretStore}
        target:
          name: ${metadata.workflowRunName}-registry-push
          creationPolicy: Owner
        data:
          - secretKey: username
            remoteRef:
              key: registry-credentials
              property: username
          - secretKey: password
            remoteRef:
              key: registry-credentials
              property: token
```

These resources are created in the workflow plane and are available to the running Argo Workflow.

---

## 7. CI workflow specifics

### Required label

```yaml
metadata:
  labels:
    openchoreo.dev/workflow-type: "component"
```

Without this label, UI and CLI won't categorize the workflow as a CI workflow, and the auto-build feature won't pick it up.

### Vendor extensions for repository fields

CI workflows must annotate repository-related schema fields with `x-openchoreo-component-parameter-repository-*` extensions. These tell OpenChoreo which fields hold the Git URL, branch, commit, app path, and secret reference — needed for auto-build (Git webhook → WorkflowRun) and UI integration.

| Extension | Purpose |
|---|---|
| `x-openchoreo-component-parameter-repository-url` | Git repository URL |
| `x-openchoreo-component-parameter-repository-branch` | Git branch |
| `x-openchoreo-component-parameter-repository-commit` | Git commit SHA |
| `x-openchoreo-component-parameter-repository-app-path` | Application path within repo |
| `x-openchoreo-component-parameter-repository-secret-ref` | SecretReference name for Git credentials |

Field structure (nesting, names) is flexible — OpenChoreo discovers fields by walking the schema for these extensions. Set each to `true`:

```yaml
parameters:
  openAPIV3Schema:
    type: object
    required: [repository]
    properties:
      repository:
        type: object
        required: [url]
        properties:
          url:
            type: string
            x-openchoreo-component-parameter-repository-url: true
          secretRef:
            type: string
            default: ""
            x-openchoreo-component-parameter-repository-secret-ref: true
          revision:
            type: object
            default: {}
            properties:
              branch:
                type: string
                default: main
                x-openchoreo-component-parameter-repository-branch: true
              commit:
                type: string
                default: ""
                x-openchoreo-component-parameter-repository-commit: true
          appPath:
            type: string
            default: "."
            x-openchoreo-component-parameter-repository-app-path: true
```

Extensions are **required** if the workflow supports auto-build, **recommended** otherwise for richer UI behavior.

### `WorkflowRun` labels

Component-triggered runs carry these labels, which the Workflow can consume via CEL:

```yaml
metadata:
  labels:
    openchoreo.dev/component: greeter-service
    openchoreo.dev/project: default
```

```yaml
${metadata.labels['openchoreo.dev/component']}
${metadata.labels['openchoreo.dev/project']}
```

### `allowedWorkflows` governance

The primary CI governance mechanism. ComponentType lists the workflows components of that type may use:

```yaml
apiVersion: openchoreo.dev/v1alpha1
kind: ClusterComponentType
metadata:
  name: backend
spec:
  allowedWorkflows:
    - kind: ClusterWorkflow            # or Workflow (namespace-scoped)
      name: dockerfile-builder
    - kind: ClusterWorkflow
      name: gcp-buildpacks-builder
```

`kind` defaults to `ClusterWorkflow`. `name` is the workflow resource name. Only workflows in the list can be referenced by Components of that type — the Component controller rejects other choices with a `WorkflowNotAllowed` condition.

#### Common patterns

```yaml
# Strict — single approved workflow
allowedWorkflows:
  - kind: ClusterWorkflow
    name: dockerfile-builder

# Choice — multiple approved workflows
allowedWorkflows:
  - kind: ClusterWorkflow
    name: dockerfile-builder
  - kind: ClusterWorkflow
    name: gcp-buildpacks-builder
  - kind: Workflow
    name: custom-react-builder

# Language-specific
allowedWorkflows:
  - kind: ClusterWorkflow
    name: dockerfile-builder           # compiled languages
  - kind: ClusterWorkflow
    name: gcp-buildpacks-builder       # interpreted languages
```

### Default CI workflows shipped with OpenChoreo

| ClusterWorkflow | Build CWT | Use |
|---|---|---|
| `dockerfile-builder` | `containerfile-build` | Dockerfile / Containerfile / Podmanfile builds |
| `gcp-buildpacks-builder` | `gcp-buildpacks-build` | Go, Java, Node.js, Python, .NET via Google Cloud Buildpacks |
| `paketo-buildpacks-builder` | `paketo-buildpacks-build` | Java, Node.js, Python, Go, .NET, Ruby, PHP via Paketo |
| `ballerina-buildpack-builder` | `ballerina-buildpack-build` | Ballerina applications |

---

## 8. WorkflowRun validation

When a `WorkflowRun` is created with component labels (`openchoreo.dev/component`, `openchoreo.dev/project`), the WorkflowRun controller runs additional validations before execution. Failures show up in `status.conditions`:

| Validation | Reason | Description |
|---|---|---|
| Both labels required | `ComponentValidationFailed` | If one of `openchoreo.dev/project` or `openchoreo.dev/component` is set, both must be present |
| Component exists | `ComponentValidationFailed` | The referenced Component must exist in the same namespace |
| Project label matches | `ComponentValidationFailed` | The project label must match the Component's owner project |
| ComponentType exists | `ComponentValidationFailed` | The Component's ComponentType / ClusterComponentType must exist |
| Workflow allowed | `ComponentValidationFailed` | The workflow must be in the ComponentType's `allowedWorkflows` |
| Workflow matches component | `ComponentValidationFailed` | If the Component has `spec.workflow` configured, the WorkflowRun must reference the same workflow |
| Workflow exists | `WorkflowNotFound` | The referenced `Workflow` / `ClusterWorkflow` must exist |
| WorkflowPlane available | `WorkflowPlaneNotFound` | A `WorkflowPlane` must be available for the workflow |

`ComponentValidationFailed` is permanent. `WorkflowPlaneNotFound` is transient and retried automatically.

---

## 9. TTL and cleanup

### Automatic cleanup

```yaml
spec:
  ttlAfterCompletion: "7d"
```

Format: duration string without spaces — `d`, `h`, `m`, `s`. Examples: `"90d"`, `"1h30m"`, `"1d12h30m15s"`.

After a run completes (success or failure) and the TTL elapses, the WorkflowRun and its workflow-plane resources are deleted automatically.

### Manual cleanup

```bash
kubectl delete workflowrun <name>
```

Deletes the WorkflowRun and all workflow-plane resources it created.

---

## 10. Verification

### MCP-first

```text
# Read what's already there
list_cluster_workflows
get_cluster_workflow <name>                       → full spec + status

# Author a new one (apply the ClusterWorkflowTemplates first via kubectl, then create the Workflow CR)
create_cluster_workflow                           → name + spec (parameters + runTemplate + externalRefs + resources)

# Update — full-spec replacement
get_cluster_workflow <name>                       → fetch current spec
# modify locally
update_cluster_workflow                           → name + the entire modified spec

# Trigger and inspect runs
trigger_workflow_run                              → component-bound build (build toolset)
create_workflow_run                               → standalone run by workflow name with explicit parameters
list_workflow_runs                                → run history
get_workflow_run <name>                           → status.conditions, per-task phases
get_workflow_run_logs <run-name>                  → live build log lines (optional task / since_seconds; live-only)
get_workflow_run_events <run-name>                → K8s events for the run (scheduling, pod-startup failures)
# live build logs via `get_workflow_run_logs`; kubectl is the completed-run fallback:
#   kubectl logs --previous <workflow-pod> -n openchoreo-workflow-plane -c <step>
```

### `kubectl apply -f` fallback

For large `runTemplate` CEL or many-line edits, applying YAML is often easier than the MCP full-replacement update:

```bash
kubectl get workflow                             # list
kubectl get workflow dockerfile-builder -o yaml  # full YAML, status

kubectl apply -f my-workflow.yaml
kubectl get workflowrun                          # see runs
kubectl get workflowrun <name> -o yaml           # status.conditions for failures
```

For run metadata (status, per-task phase), prefer MCP (`list_workflow_runs`, `get_workflow_run`). For live build log lines, `get_workflow_run_logs <run-name>` is the primary MCP path (optional `task` filter, optional `since_seconds` bound). Pair with `get_workflow_run_events` for scheduling/pod-startup diagnostics. For completed-run failures whose live logs are gone, fall back to `kubectl logs --previous <workflow-pod> -n openchoreo-workflow-plane -c <step>`.

### kubectl for Argo CRDs

`ClusterWorkflowTemplate` (Argo native) is applied with kubectl against the workflow-plane cluster — there is no MCP path:

```bash
kubectl --context <workflow-plane> apply -f cwt-checkout.yaml
kubectl --context <workflow-plane> apply -f cwt-docker-build.yaml
```

For workload generation (how the build output produces a `Workload` CR), the API-publishing OAuth setup, the auto-build webhook flow, external CI integration, and the full Argo Workflows reference, see <https://openchoreo.dev/docs/platform-engineer-guide/workflows/>.
