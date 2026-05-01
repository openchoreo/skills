# Troubleshooting

## Table of Contents

- [General Approach](#general-approach)
- [Control Plane Issues](#control-plane-issues)
- [Data Plane Issues](#data-plane-issues)
- [Workflow Plane Issues](#workflow-plane-issues)
- [Observability Plane Issues](#observability-plane-issues)
- [Connectivity Issues](#connectivity-issues)
- [Common Failure Patterns](#common-failure-patterns)

## General Approach

Start from the plane where the failure manifests, then work outward.

> **Tool order for diagnostics.** For OpenChoreo CRD inspection (Component, Workload, ReleaseBinding, Environment, plane status), use **MCP first** — `get_component`, `get_release_binding`, `get_dataplane`, etc. all return spec + `status.conditions[]`. For per-binding data-plane drill-down, use `get_resource_events` and `get_resource_logs`. Drop to **kubectl** only when MCP can't reach what you need: controller / cluster-gateway / cluster-agent pod logs, raw cluster-wide CRD inspection, fluent-bit / OpenSearch logs.

### Health check — MCP path (read OpenChoreo CRD status)

```
get_component <name>                        → status.conditions, dependent resources
get_workload <name>                         → container, endpoints, status
get_release_binding <name>                  → per-environment readiness, deployed URLs
get_dataplane <name>                         → plane connectivity, gateway config, agent state
get_workflowplane <name>                    → workflow plane state
get_observability_plane <name>              → observer endpoint, agent state
list_release_bindings <component>           → see all envs the component is deployed to

get_resource_events                          → K8s events on Deployment / Pod under a binding
                                                (image pull errors, scheduling failures, OOM)
get_resource_logs                            → raw container logs for a specific pod under a binding
                                                (crashloops, startup failures)
```

> For longer-horizon log/metric/trace history, alerts, or incidents, drop to `kubectl logs` against the appropriate plane (see the kubectl path below). Build logs go through MCP — `get_workflow_run_logs` (live) and `get_workflow_run_events` for the same run.

### Diagnostic-tool gotchas

- **`get_resource_events` parameters are exact-match.** Required: `namespace_name`, `release_binding_name`, `group`, `version`, `kind`, `resource_name`. For core resources, `group: ""`. Use `get_release_binding` first to discover the kind/name of the workload's Deployment / Pod.
- **`get_resource_logs` is direct kubectl-style logs.** It goes through the cluster gateway to the data plane, not through the observer store. Pod must currently exist; previous-container logs are not retrievable. For pods that are gone, fall back to `kubectl logs --previous` against the data-plane cluster directly.
- **`get_workflow_run_logs` is live-only.** Returns nothing once a run has finished. For *completed* failed runs, fall back to `kubectl logs --previous <argo-pod> -n openchoreo-workflow-plane -c <step>`. Pair `get_workflow_run_events` for scheduling / pod-startup diagnostics that don't need live container output.
- **ObservabilityPlane (the CRD) must be installed and healthy** for the in-cluster observability stack to ingest data. If `kubectl logs` against `observer` / `fluent-bit` / `opensearch` shows pipeline failures, inspect plane registration via `get_observability_plane` and `kubectl get observabilityplane <name> -o yaml`.

### Health check — kubectl path (cluster pods, controllers, raw CRDs)

```bash
# Plane pod status (no MCP equivalent)
kubectl get pods -n openchoreo-control-plane
kubectl get pods -n openchoreo-data-plane
kubectl get pods -n openchoreo-workflow-plane
kubectl get pods -n openchoreo-observability-plane

# Cluster-wide raw CRD view (use when MCP filters don't fit, or for non-OpenChoreo CRDs)
kubectl get <crd> -A
```

### Log locations

| Component | Namespace | How to access |
|-----------|-----------|---------------|
| Controller Manager | `openchoreo-control-plane` | `kubectl logs deployment/controller-manager -n openchoreo-control-plane` |
| OpenChoreo API | `openchoreo-control-plane` | `kubectl logs deployment/openchoreo-api -n openchoreo-control-plane` |
| Cluster Gateway | `openchoreo-control-plane` | `kubectl logs deployment/cluster-gateway -n openchoreo-control-plane` |
| Data Plane Agent | `openchoreo-data-plane` | `kubectl logs deployment/cluster-agent -n openchoreo-data-plane` |
| Workflow Plane Agent | `openchoreo-workflow-plane` | `kubectl logs deployment/cluster-agent -n openchoreo-workflow-plane` |
| Observer | `openchoreo-observability-plane` | `kubectl logs deployment/observer -n openchoreo-observability-plane` |
| Fluent Bit | `openchoreo-observability-plane` | `kubectl logs -l app.kubernetes.io/name=fluent-bit -n openchoreo-observability-plane` |
| OpenSearch | `openchoreo-observability-plane` | `kubectl logs -l app=opensearch -n openchoreo-observability-plane` |

## Control Plane Issues

### Controller Manager not reconciling

```bash
kubectl logs deployment/controller-manager -n openchoreo-control-plane --tail=100
kubectl get events -n openchoreo-control-plane --sort-by='.lastTimestamp'
```

Common causes:
- RBAC permissions missing for a CRD (check for "forbidden" errors)
- Webhook certificate expired (check cert-manager)
- Resource validation failing (check admission webhook logs)

### OpenChoreo API errors

```bash
kubectl logs deployment/openchoreo-api -n openchoreo-control-plane --tail=100
```

Common causes:
- Database connectivity (SQLite file permissions or PostgreSQL connection)
- OIDC misconfiguration (issuer mismatch, JWKS unreachable)
- Authorization policy errors


## Data Plane Issues

### Workloads not deploying

```
# Check the resource chain — MCP
get_component <name>                            → status.conditions
get_release_binding <binding>                   → per-env readiness, condition messages
get_resource_events                             → K8s events on the Deployment / Pod
                                                  (kind: Deployment / Pod, group: apps / "")
get_resource_logs                               → raw container logs for a crashing pod
```

```bash
# Check data plane agent (kubectl — no MCP path for plane pod logs)
kubectl logs deployment/cluster-agent -n openchoreo-data-plane --tail=50

# Inspect the rendered K8s resources directly when needed
kubectl get deployments -n <cell-namespace>
kubectl describe deployment <name> -n <cell-namespace>
kubectl get events -n <cell-namespace> --sort-by='.lastTimestamp'
```

Common causes:
- Agent disconnected from Control Plane
- ComponentType template rendering error (check conditions)
- Missing image pull secrets
- Resource quota exceeded
- Gateway not configured for the endpoint visibility level

### Endpoints not accessible

```
# Check release binding status for URLs (MCP)
get_release_binding <binding>                   → status.endpoints[], invokeURL, externalURLs
```

```bash
# Inspect Gateway API resources (kubectl — Gateway API is upstream K8s, not OpenChoreo)
kubectl get gateway -A
kubectl get httproute -A
kubectl describe httproute <name> -n <ns>
```

Common causes:
- Northbound gateway not configured (for external endpoints)
- Westbound gateway not configured (for internal/namespace endpoints)
- TLS certificate not provisioned
- DNS not pointing to LoadBalancer

## Workflow Plane Issues

### Builds not starting

```
# Check WorkflowRun status (MCP)
list_workflow_runs                              → recent runs for namespace / project / component
get_workflow_run <name>                         → status.conditions, per-task phases
get_workflowplane <name>                        → workflow plane registration / agent state
```

```bash
# Workflow plane internals (kubectl — no MCP path for plane pod logs / Argo CR)
kubectl logs deployment/cluster-agent -n openchoreo-workflow-plane --tail=50
kubectl get pods -n openchoreo-workflow-plane
kubectl logs deployment/argo-workflows-workflow-controller -n openchoreo-workflow-plane --tail=50
kubectl get workflows.argoproj.io -n openchoreo-workflow-plane
```

Common causes:
- WorkflowPlane CR not registered in Control Plane
- Agent disconnected
- Argo Workflows controller not running
- ClusterWorkflowTemplate missing

### Build failures

```
# Identify which step failed (MCP)
list_workflow_runs                              → find the run name first
get_workflow_run <name>                         → status.conditions + per-task phases
get_workflow_run_logs <run-name> [task=<step>] [since_seconds=N]
                                                → live build log lines (live-only — nothing for completed runs)
get_workflow_run_events <run-name> [task=<step>]
                                                → K8s events for the run (scheduling, pod-startup failures)
```

```
# Build log content — MCP first
get_workflow_run_logs <run-name> [task=<step>] [since_seconds=N]
                                                → live log lines from the run's task pods
get_workflow_run_events <run-name> [task=<step>]
                                                → K8s events (scheduling, image pull, pod startup)
```

```bash
# Completed-run fallback: the live-log endpoint returns nothing once a run finishes,
# so for failed-and-finished runs drop to kubectl against the workflow plane.
kubectl get pods -n openchoreo-workflow-plane -l workflows.argoproj.io/workflow
kubectl logs --previous <workflow-pod> -n openchoreo-workflow-plane -c <step-name>
```

Common causes:
- Registry push credentials invalid or missing
- Dockerfile not found (wrong `docker.context` or `docker.filePath`)
- `generate-workload-cr` step failing (missing `workload.yaml` at `appPath` root)
- Source repo access denied (missing `secretRef`)

## Observability Plane Issues

### Logs not appearing

```bash
# Check Fluent Bit
kubectl get pods -n openchoreo-observability-plane -l app.kubernetes.io/name=fluent-bit
kubectl logs -l app.kubernetes.io/name=fluent-bit -n openchoreo-observability-plane --tail=50

# Check OpenSearch
kubectl get pods -n openchoreo-observability-plane -l app=opensearch
kubectl logs -l app=opensearch -n openchoreo-observability-plane --tail=50

# Check Observer API
kubectl logs deployment/observer -n openchoreo-observability-plane --tail=50
```

Common causes:
- Fluent Bit output misconfigured (wrong OpenSearch endpoint)
- OpenSearch cluster not ready (storage issues, resource limits)
- ObservabilityPlane CR not registered
- In multi-cluster: agent disconnected or telemetry export config wrong

### Metrics not available

```bash
kubectl get pods -n openchoreo-observability-plane -l app.kubernetes.io/name=prometheus
kubectl get servicemonitors --all-namespaces
```

### Traces not arriving

```bash
kubectl get pods -n openchoreo-observability-plane -l app.kubernetes.io/name=opentelemetry-collector
kubectl logs -l app.kubernetes.io/name=opentelemetry-collector -n openchoreo-observability-plane --tail=50
```

### Alerts not triggering

```bash
kubectl get observabilityalertrules -n <namespace>
kubectl describe observabilityalertrule <name> -n <namespace>
kubectl logs deployment/observer -n openchoreo-observability-plane --tail=50
```

## Connectivity Issues

### Agent not connecting to Control Plane

```bash
# On remote cluster
kubectl logs deployment/cluster-agent -n <agent-namespace> --tail=50

# On control plane
kubectl logs deployment/cluster-gateway -n openchoreo-control-plane --tail=50
```

Checklist:
1. Is the Cluster Gateway reachable from the remote cluster? (network/firewall)
2. Do the certificate SANs match the connection URL?
3. Is the CA ConfigMap present in the agent namespace?
4. Has the agent's client CA been embedded in the plane CR?
5. Has cert-manager issued the certificates? `kubectl get certificate -A`

### Certificate issues

```bash
# Check cert-manager
kubectl get certificate -A
kubectl describe certificate <name> -n <ns>
kubectl logs deployment/cert-manager -n cert-manager --tail=50

# Check if secrets exist
kubectl get secret cluster-gateway-ca -n openchoreo-control-plane
kubectl get secret cluster-agent-tls -n <agent-namespace>
```

## Common Failure Patterns

### Resources stuck in "Pending"

1. Check if the target plane agent is connected
2. Check controller-manager logs for reconciliation errors
3. Check if the namespace has the `openchoreo.dev/controlplane-namespace=true` label

### "forbidden" errors in controller logs

Missing RBAC for a CRD. The agent service accounts are:
- Data Plane: `cluster-agent-dataplane` in `openchoreo-data-plane`
- Workflow Plane: `cluster-agent-workflowplane` in `openchoreo-workflow-plane`
- Observability Plane: `cluster-agent-observabilityplane` in `openchoreo-observability-plane`

### Webhook validation failures

When a ComponentType, Trait, or Component fails to apply:

```bash
# Check webhook logs
kubectl logs deployment/controller-manager -n openchoreo-control-plane --tail=50 | grep -i webhook

# Check if webhook is registered
kubectl get validatingwebhookconfigurations | grep openchoreo
```

Common causes: invalid CEL expressions in templates, schema syntax errors, references to non-existent traits or workflows.

### Cluster agent RBAC for third-party CRDs

When using CRDs not shipped with OpenChoreo (Istio, Knative, cert-manager, Prometheus Operator), the agent needs additional permissions:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: openchoreo-custom-resources
rules:
  - apiGroups: ["monitoring.coreos.com"]
    resources: ["servicemonitors"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: openchoreo-custom-resources-binding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: openchoreo-custom-resources
subjects:
  - kind: ServiceAccount
    name: cluster-agent-dataplane
    namespace: openchoreo-data-plane
```
