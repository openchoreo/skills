## Prerequisites

- `node` (≥ v18) on PATH — the skill runs a tiny local preview server for the plan
- A renderer for your source: `helm` (≥ v3.12) for charts, `kustomize` (or `kubectl`) for overlays, nothing extra for Docker Compose or raw Kubernetes YAML
- A browser to view the plan

## Use cases

Plan how an existing application maps onto OpenChoreo. **Plans only — never applies to a cluster.**

- Migrate an app (Helm chart, Kustomize overlay, Docker Compose file, or raw Kubernetes YAML)
- Audit a large umbrella for "what moves first" — Components grouped into Projects, dependencies wired, out-of-scope pieces flagged
- Identify the CTs / RTs / Traits to author at the pattern level (reusable across many Components)
- Architecture map of an inherited app — cell diagram + dependency wiring + gap list

## Samples

### Import a Helm chart

```text
Plan importing the Online Boutique helm chart into OpenChoreo.
```

Try with [GoogleCloudPlatform/microservices-demo](https://github.com/GoogleCloudPlatform/microservices-demo/tree/main/helm-chart).

### Import raw Kubernetes manifests

```text
Plan importing the Bank of Anthos Kubernetes manifests into OpenChoreo.
```

Try with [GoogleCloudPlatform/bank-of-anthos](https://github.com/GoogleCloudPlatform/bank-of-anthos/tree/main/kubernetes-manifests).

