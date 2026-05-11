# Author a CI Workflow

Author a `ClusterWorkflow` that developers can reference from `Component.spec.workflow` to build container images from source. **Two halves**: the OpenChoreo `Workflow` CRD (parameter schema + inline `runTemplate`) is MCP-driven; the underlying Argo `ClusterWorkflowTemplate`s (the actual build steps) are `kubectl apply -f` against the WorkflowPlane.

> **Prerequisite Argo Workflows knowledge.** This recipe assumes you can read an Argo `Workflow` spec — `templates`, `steps`, `templateRef`, `arguments`, `volumeClaimTemplates`. If not, read <https://argo-workflows.readthedocs.io/> first; OpenChoreo doesn't reinvent that surface.

## When to use

- You want to add a new build strategy not shipped with OpenChoreo (e.g. a custom Bazel builder, a multi-stage compile + scan pipeline, a vendor-specific buildpack)
- You want to wrap an existing builder with extra steps (Trivy scan, SBOM emit, attestation)
- You want a CI workflow scoped to a single namespace (tenant-private builders) — see **Variants**

For an off-the-shelf builder, OpenChoreo ships `dockerfile-builder`, `gcp-buildpacks-builder`, `paketo-buildpacks-builder`, `ballerina-buildpack-builder`. List with `list_cluster_workflows`. Don't author a new one if a default fits.

## Prerequisites

1. The control-plane MCP server is configured (`list_namespaces` returns).
2. **`kubectl` access to the WorkflowPlane cluster** (where the Argo `ClusterWorkflowTemplate`s live). For single-cluster installs, this is the same cluster as the control plane; for multi-cluster, switch contexts.
3. A `WorkflowPlane` (or `ClusterWorkflowPlane`) is registered and healthy. Verify with `list_cluster_workflowplanes` / `get_cluster_workflowplane`.
4. Familiarity with the doc walkthrough: <https://openchoreo.dev/docs/platform-engineer-guide/workflows/creating-workflows> — it walks through the same 3-step process from a docs angle.
5. The 4 canonical Argo `ClusterWorkflowTemplate`s for the Dockerfile path ship with this skill at [`../../resources/workflow-templates/`](../../resources/workflow-templates/) — `checkout-source.yaml`, `containerfile-build.yaml`, `publish-image.yaml`, `generate-workload.yaml`. To inspect a real OpenChoreo `Workflow` CRD that wires them together, `get_cluster_workflow name: dockerfile-builder` (the platform usually ships this).

## Recipe

The 3-step authoring process from [`../workflows.md`](../workflows.md) §3, mapped to which tool surface owns each step:

| Step | What | Where | Tool |
|---|---|---|---|
| 1 | Author the `ClusterWorkflowTemplate`(s) — actual step logic | WorkflowPlane | `kubectl apply -f` |
| 2 | Design the Argo Workflow shape — pipeline structure, parameters | (paper / scratchpad) | none |
| 3 | Create the OpenChoreo `Workflow` / `ClusterWorkflow` CR — schema + embedded `runTemplate` | Control plane | `create_cluster_workflow` |

### Step 1 — Apply the ClusterWorkflowTemplates (kubectl)

Each `ClusterWorkflowTemplate` defines **one reusable step** (clone, build, push, generate-workload). They live in the workflow plane and are referenced from the OpenChoreo Workflow's `runTemplate.spec.templates[].steps[].templateRef`.

The 4 canonical CWTs ship with this skill — apply each one against the WorkflowPlane:

```bash
kubectl --context <workflow-plane> apply -f resources/workflow-templates/checkout-source.yaml
kubectl --context <workflow-plane> apply -f resources/workflow-templates/containerfile-build.yaml
kubectl --context <workflow-plane> apply -f resources/workflow-templates/publish-image.yaml
kubectl --context <workflow-plane> apply -f resources/workflow-templates/generate-workload.yaml
```

What each one does:

- [`checkout-source.yaml`](../../resources/workflow-templates/checkout-source.yaml) — git clone with auth options (SSH key, basic auth, public)
- [`containerfile-build.yaml`](../../resources/workflow-templates/containerfile-build.yaml) — podman / buildah build from a Containerfile
- [`publish-image.yaml`](../../resources/workflow-templates/publish-image.yaml) — push to the configured registry using the platform-resolved push secret
- [`generate-workload.yaml`](../../resources/workflow-templates/generate-workload.yaml) — emit the auto-generated `Workload` CR back to the control plane

For buildpack-based builds (Paketo, GCP Buildpacks, Ballerina), `containerfile-build.yaml` is replaced with a buildpack CWT — fetch the upstream alternative (`samples/getting-started/workflow-templates/{paketo,gcp,ballerina}-buildpack-build.yaml`) when needed.

### Step 2 — Design the Argo Workflow shape

Decide the pipeline before writing the CR. Categorize each parameter into one of three types — see [`../workflows.md`](../workflows.md) §3 *Step 2* for the full breakdown:

- **Hard-coded** — platform engineer locks the value (`trivy-scan: "true"`, registry hostname, image-tag scheme)
- **Developer-provided** — filled in via `WorkflowRun.spec.workflow.parameters` (repo URL, branch, appPath)
- **System-generated** — injected via CEL at run time (`${metadata.workflowRunName}`, `${metadata.namespaceName}`, `${externalRefs[...].spec.*}`)

For CI workflows specifically, the developer-provided parameters that drive auto-build (`repository.url`, `repository.revision.branch`, `repository.revision.commit`, `repository.appPath`, `repository.secretRef`) **must carry the `x-openchoreo-component-parameter-repository-*` schema annotations** — see Step 3.

### Step 3 — Create the OpenChoreo Workflow CR (MCP)

```yaml
list_cluster_workflows                # sanity-check existing names
create_cluster_workflow
  name: my-custom-builder
  spec:
    workflowPlaneRef:
      kind: ClusterWorkflowPlane
      name: default
    ttlAfterCompletion: "1d"

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

    externalRefs:
      - id: git-secret-reference
        apiVersion: openchoreo.dev/v1alpha1
        kind: SecretReference
        name: ${parameters.repository.secretRef}

    runTemplate:
      apiVersion: argoproj.io/v1alpha1
      kind: Workflow
      metadata:
        name: ${metadata.workflowRunName}
        namespace: ${metadata.namespace}
      spec:
        serviceAccountName: workflow-sa
        entrypoint: build-workflow
        arguments: { ... }                  # parameters bound from CEL
        templates:
          - name: build-workflow
            steps:
              - - name: checkout-source
                  templateRef: { name: checkout-source, clusterScope: true, template: checkout }
              - - name: build-image
                  templateRef: { name: my-custom-build, clusterScope: true, template: build-image }
              - - name: publish-image
                  templateRef: { name: publish-image, clusterScope: true, template: publish-image }
              - - name: generate-workload-cr
                  templateRef: { name: generate-workload, clusterScope: true, template: generate-workload-cr }
        volumeClaimTemplates:
          - metadata: { name: workspace }
            spec:
              accessModes: [ReadWriteOnce]
              resources: { requests: { storage: 2Gi } }

    resources:                              # auxiliary CRs (ExternalSecrets for git auth, registry push)
      - id: git-secret
        includeWhen: ${has(parameters.repository.secretRef) && parameters.repository.secretRef != ""}
        template: { ... }                   # ExternalSecret resolving the SecretReference into a workflow-plane Secret
```

For the metadata block, **the `openchoreo.dev/workflow-type: "component"` label is required** for the workflow to register as CI:

```yaml
metadata:
  name: my-custom-builder
  labels:
    openchoreo.dev/workflow-type: "component"
```

Pass this through the MCP `create_cluster_workflow` call (the tool accepts a `metadata.labels` field on the resource). Without it, UI / CLI won't categorize the workflow as CI and auto-build won't pick it up. See [`../workflows.md`](../workflows.md) §7.

For the full body — including the registry-push ExternalSecret, the per-step CEL expressions, and the proper `runTemplate.spec.arguments.parameters`-to-CWT-arg wiring — inspect a Workflow already on the cluster: `get_cluster_workflow name: dockerfile-builder` (the platform usually ships this and the three buildpack alternatives). Adapt the returned spec.

### Step 4 — Allow the workflow on at least one ComponentType

A CI workflow is unusable until a ComponentType lists it in `allowedWorkflows`. Either author a new type via [`./author-a-componenttype.md`](./author-a-componenttype.md) with this workflow allowed, or update an existing one.

### Step 5 — Verify

```yaml
get_cluster_workflow
  name: my-custom-builder
```

Then trigger a real build from the developer side:

```yaml
create_component
  workflow:
    kind: ClusterWorkflow
    name: my-custom-builder
    parameters: { ... }
trigger_workflow_run
  component_name: <test>
list_workflow_runs
get_workflow_run
get_workflow_run_logs        # live; returns nothing once the run finishes
```

For *completed* failed runs, the live-log endpoint returns nothing — fall back to `kubectl logs --previous <argo-pod> -n openchoreo-workflow-plane -c <step>`. Pair with `get_workflow_run_events` for scheduling / pod-startup diagnostics.

## Variants

### Different builder strategies

Default OpenChoreo platform setups usually ship four `ClusterWorkflow`s — inspect each with `get_cluster_workflow name: <name>`:

| Workflow name | Builder |
|---|---|
| `dockerfile-builder` | Dockerfile / Containerfile / Podmanfile |
| `gcp-buildpacks-builder` | Google Cloud Buildpacks (Go, Java, Node, Python, .NET) |
| `paketo-buildpacks-builder` | Paketo (Java, Node, Python, Go, .NET, Ruby, PHP) |
| `ballerina-buildpack-builder` | Ballerina |

To wrap one with extra steps (Trivy scan, SBOM, attestation), copy the closest variant, add the new steps in `runTemplate.spec.templates[0].steps`, and apply the corresponding `ClusterWorkflowTemplate` for each new step.

### Namespace-scoped `Workflow`

Tenant-private builder, or a one-off custom builder for a single team:

```yaml
create_workflow
  namespace_name: acme
  name: tenant-builder
  spec: { ... }
```

A namespace-scoped `Workflow` may only be referenced from a `ComponentType` (namespace-scoped) or from a `ClusterComponentType` whose `allowedWorkflows` lists it (rare — `ClusterComponentType.allowedWorkflows` typically points at `ClusterWorkflow`s).

## Gotchas

- **`openchoreo.dev/workflow-type: "component"` label is required** for CI registration. Without it, UI / CLI won't categorize the workflow and auto-build won't fire.
- **`x-openchoreo-component-parameter-repository-*` annotations enable auto-fill from `Component.spec.workflow.parameters`** and webhook-driven auto-build. Required if you want auto-build; recommended otherwise for richer UI behavior. The annotation values are `true` (booleans) on each schema field.
- **`update_*` is full-spec replacement.** `get_*` first, modify, send back. For big `runTemplate` CEL edits, `kubectl apply -f` against the YAML is often easier.
- **`ClusterWorkflowTemplate` lives in the WorkflowPlane cluster, not the control plane.** Apply against the WorkflowPlane context.
- **`runTemplate` is an *inline* Argo Workflow spec, not a reference.** The CEL-templated `runTemplate` becomes the actual `argoproj.io/v1alpha1 Workflow` at run time. `metadata.name: ${metadata.workflowRunName}` and `metadata.namespace: ${metadata.namespace}` are required so each run lands in the workflow plane correctly.
- **`externalRefs[]` resolve external CRs (today only `SecretReference`) before the run starts.** Pair with `includeWhen` on `resources[]` that depend on them — if `parameters.repository.secretRef` is empty, the `git-secret` ExternalSecret should be skipped.
- **Each `WorkflowRun` is imperative.** Trigger via MCP (`trigger_workflow_run` / `create_workflow_run`), webhook, or one-shot `kubectl apply`.
- **`WorkflowPlane` must exist and be healthy.** A workflow with `workflowPlaneRef` pointing at a non-existent / unhealthy plane stays stuck — `get_workflow_run.status.conditions` will show `WorkflowPlaneNotFound`.
- **The `workflow` field on a `WorkflowRun` is immutable.** Once a run exists, you can't re-target it to a different workflow — create a new run.
- **Don't bake registry credentials into the runTemplate.** Use `externalRefs` + `resources[].template` to materialize an ExternalSecret at run time. The push secret is typically a `SecretReference` named `registry-push-secret` (or similar) — reference it via the workflow plane's configured `ClusterSecretStore`.

## Related

- [`../workflows.md`](../workflows.md) — full topical reference (multi-plane architecture, schema syntax with the `required: []` rule, externalRefs, resources, CI-specific labels and annotations, WorkflowRun validation, TTL)
- [`../cel.md`](../cel.md) — CEL contexts available in `runTemplate` and `resources` (workflow-only variables: `metadata.workflowRunName`, `metadata.namespaceName`, `workflowplane.secretStore`, `externalRefs[<id>]`)
- [`./author-a-generic-workflow.md`](./author-a-generic-workflow.md) — for non-CI standalone automation
- [`./author-a-componenttype.md`](./author-a-componenttype.md) — the type that lists this workflow in `allowedWorkflows`
- Argo Workflows reference: <https://argo-workflows.readthedocs.io/>
- OpenChoreo doc walkthrough: <https://openchoreo.dev/docs/platform-engineer-guide/workflows/creating-workflows>
