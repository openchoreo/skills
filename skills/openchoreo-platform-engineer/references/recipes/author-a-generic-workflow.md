# Author a Generic (non-CI) Workflow

Author a `ClusterWorkflow` for ad-hoc automation that isn't tied to a Component build — Terraform / Pulumi infra provisioning, ETL jobs, end-to-end test runs, package publishing, custom container builds. Two halves like CI workflows: the OpenChoreo `Workflow` CRD is MCP-driven; the underlying Argo `ClusterWorkflowTemplate`s are `kubectl apply -f`.

> **Prerequisite Argo Workflows knowledge.** Same as the CI-workflow recipe — read https://argo-workflows.readthedocs.io/ if you don't already know the `templates` / `steps` / `templateRef` model.

## When to use

- Infrastructure provisioning (Terraform, Pulumi, Crossplane reconciliation runs)
- Data pipelines / ETL — periodic batch jobs that don't fit the `cronjob` ComponentType pattern
- End-to-end test suites kicked off manually or on a schedule
- Package publishing (npm, PyPI, Maven, container registry) outside of a component build
- Custom Docker builds that aren't tied to a deployed Component

For workflows that build images for OpenChoreo Components (developer triggers `trigger_workflow_run` against a Component), see [`./author-a-ci-workflow.md`](./author-a-ci-workflow.md) instead — those need extra labels and schema annotations.

## Prerequisites

1. The control-plane MCP server is configured (`list_namespaces` returns).
2. `kubectl` access to the WorkflowPlane cluster (for the Argo `ClusterWorkflowTemplate` half).
3. A `WorkflowPlane` (or `ClusterWorkflowPlane`) registered and healthy.
4. Familiarity with the Workflow CRD shape — see [`../workflows.md`](../workflows.md) §1–§6 for the parts shared with CI workflows.

## Recipe

### 1. Apply the Argo `ClusterWorkflowTemplate`(s) (kubectl)

For each reusable step, write the CWT and apply against the workflow plane. There's no off-the-shelf set for generic workflows — compose from the CI CWTs that ship with this skill ([`../../resources/workflow-templates/`](../../resources/workflow-templates/) — `checkout-source.yaml` etc.) or write fresh ones for your domain.

```bash
kubectl --context <workflow-plane> apply -f terraform-apply.yaml
kubectl --context <workflow-plane> apply -f notify-slack.yaml
```

For step shape reference: [`../../resources/workflow-templates/checkout-source.yaml`](../../resources/workflow-templates/checkout-source.yaml) shows inputs / outputs / `volumeMounts` / `args` / `securityContext` patterns.

### 2. Create the OpenChoreo Workflow CR (MCP)

```
list_cluster_workflows           # sanity-check; don't duplicate
create_cluster_workflow
  name: terraform-runner
  spec:
    workflowPlaneRef:
      kind: ClusterWorkflowPlane
      name: default
    ttlAfterCompletion: "7d"

    parameters:
      openAPIV3Schema:
        type: object
        required: [moduleSource]
        properties:
          moduleSource:
            type: string
            description: "Git URL to a Terraform module"
          variables:
            type: object
            additionalProperties: { type: string }
            default: {}
          secretRef:
            type: string
            default: ""
            description: "SecretReference name carrying cloud-provider credentials"

    externalRefs:
      - id: cloud-creds
        apiVersion: openchoreo.dev/v1alpha1
        kind: SecretReference
        name: ${parameters.secretRef}

    runTemplate:
      apiVersion: argoproj.io/v1alpha1
      kind: Workflow
      metadata:
        name: ${metadata.workflowRunName}
        namespace: ${metadata.namespace}
      spec:
        serviceAccountName: workflow-sa
        entrypoint: pipeline
        arguments:
          parameters:
            - name: module-source
              value: ${parameters.moduleSource}
            # ... developer-provided + system-generated parameters
        templates:
          - name: pipeline
            steps:
              - - name: terraform-apply
                  templateRef: { name: terraform-apply, clusterScope: true, template: apply }
              - - name: notify-slack
                  templateRef: { name: notify-slack, clusterScope: true, template: notify }
        volumeClaimTemplates:
          - metadata: { name: workspace }
            spec:
              accessModes: [ReadWriteOnce]
              resources: { requests: { storage: 1Gi } }

    resources:
      - id: cloud-credentials
        includeWhen: ${has(parameters.secretRef) && parameters.secretRef != ""}
        template:
          apiVersion: external-secrets.io/v1
          kind: ExternalSecret
          metadata:
            name: ${metadata.workflowRunName}-cloud-creds
            namespace: ${metadata.namespace}
          spec: { ... }              # standard ExternalSecret pattern; see workflows.md §5
```

**Notable differences from a CI workflow:**

- **No `openchoreo.dev/workflow-type: "component"` label.** Without it, the workflow won't be treated as a CI workflow by the UI / CLI / auto-build path — which is exactly what we want for generic automation.
- **No `x-openchoreo-component-parameter-repository-*` schema annotations.** Generic workflows don't auto-fill repository fields from a Component spec.
- **No expectation of a `generate-workload-cr` step.** Generic workflows don't emit `Workload` CRs.

### 3. Verify with a standalone run

Generic workflows are invoked via `create_workflow_run` (standalone), not `trigger_workflow_run` (which is component-bound):

```
create_workflow_run
  namespace_name: default
  workflow:
    kind: ClusterWorkflow
    name: terraform-runner
    parameters:
      moduleSource: https://github.com/acme/terraform-aws-vpc.git
      variables:
        region: us-east-1
        cidr: "10.0.0.0/16"
      secretRef: aws-creds-prod
list_workflow_runs
get_workflow_run
get_workflow_run_logs        # live; returns nothing for completed runs
get_workflow_run_events
```

For *completed* failed runs, fall back to `kubectl logs --previous <argo-pod> -n openchoreo-workflow-plane -c <step>` against the workflow plane.

## Recipe — updating

`update_*` is full-spec replacement:

```
get_cluster_workflow
  cwf_name: terraform-runner
# Modify locally
update_cluster_workflow
  name: terraform-runner
  spec: <complete modified spec>
```

For one-line `runTemplate` CEL tweaks, `kubectl apply -f` against an edited YAML is often easier.

## Variants

### Namespace-scoped `Workflow`

For tenant-private generic workflows (per-team Terraform modules, tenant-specific ETL pipelines):

```
create_workflow
  namespace_name: acme
  name: tenant-etl
  spec: { ... }
```

Namespace-scoped Workflows are invoked via `create_workflow_run namespace_name: acme workflow.name: tenant-etl` (the run lives in the same namespace).

## Gotchas

- **Use `create_workflow_run` (standalone), not `trigger_workflow_run`.** `trigger_workflow_run` is the component-bound build path — it requires a `component_name` and resolves the workflow from `Component.spec.workflow`. Standalone runs use `create_workflow_run` with explicit `workflow.name` + `workflow.parameters`.
- **Standalone runs don't carry component labels by default.** If you want traceability (audit, alert routing), add labels via the `metadata.labels` field on the run. The `openchoreo.dev/component` and `openchoreo.dev/project` labels are reserved for component-bound runs — if set on a standalone run, the WorkflowRun controller will run component-validation and reject the run if no matching component exists.
- **No CI-specific extensions.** Don't add `openchoreo.dev/workflow-type: "component"` or `x-openchoreo-component-parameter-repository-*` to a generic workflow — those activate component-tied behavior you don't want here.
- **TTL matters more for generic workflows.** CI workflows turn over fast; generic workflows (Terraform applies, ETL runs) can accumulate. Set `ttlAfterCompletion` (e.g. `"7d"`, `"30d"`) deliberately. Format: `d` / `h` / `m` / `s`, no spaces.
- **Service-account permissions.** The default `workflow-sa` in the workflow plane has narrow permissions. For workflows that need broader access (e.g. Terraform creating cloud resources via mounted credentials, or jobs that call back to the control plane), grant the service account the right ClusterRoles via `kubectl apply -f` in the workflow plane.
- **`update_*` is full-spec replacement.** Always `get_*` first.
- **`ClusterWorkflowTemplate` lives in the workflow plane.** Apply via `kubectl apply -f` against the WorkflowPlane context.
- **Imperative runs.** Don't commit `WorkflowRun` YAML to GitOps — it'll trigger duplicate runs on reconcile.

## Related

- [`../workflows.md`](../workflows.md) — full topical reference (multi-plane architecture, schema syntax, externalRefs, resources, TTL, verification flow)
- [`../cel.md`](../cel.md) — CEL contexts in `runTemplate` and `resources` (workflow-only variables: `metadata.workflowRunName`, `metadata.namespaceName`, `workflowplane.secretStore`, `externalRefs[<id>]`)
- [`./author-a-ci-workflow.md`](./author-a-ci-workflow.md) — for component-bound build workflows (different labels, different schema annotations, different invocation path)
- Argo Workflows reference: https://argo-workflows.readthedocs.io/
