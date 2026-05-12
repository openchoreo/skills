## Prerequisites

- `kubectl` (≥ v1.32) and `helm` (≥ v3.12) on PATH
- For local k3d: Docker and `k3d` (≥ v5.8)
- For an existing cluster: working `kubectl` access with cluster-admin, a LoadBalancer-capable provider, and a default StorageClass

## Use cases

Use this skill for first-time OpenChoreo installs:

- Spin up a fresh OpenChoreo install on local k3d to try it out or develop against
- Install OpenChoreo onto a managed Kubernetes cluster (GKE, EKS, AKS, DOKS, or self-managed)
- Bootstrap OpenChoreo on Rancher Desktop or k3s for a local-but-real environment
- Install a subset of planes (skip the workflow or observability plane) when you don't need the full stack yet

## Samples

### Try OpenChoreo locally

Get a working OpenChoreo install on your laptop. The agent walks the install guide end-to-end and surfaces the easy-to-miss bits (Apple Silicon Colima recommendation, `K3D_FIX_DNS=0`, Fluent Bit `machine-id`).

```text
Set me up an openchoreo cluster locally using k3d
```

Alternatively, install on Rancher Desktop — the agent applies the pre-install runtime / traefik tweaks for you (via `rdctl` if available, otherwise it talks you through the GUI).

```text
Set me up an openchoreo cluster locally using Rancher Desktop
```

Or go lean on k3d and skip the observability plane.

```text
Set me up an openchoreo cluster locally using k3d, without the observability plane
```

### Install on a managed Kubernetes cluster

Prereq: you've already wired your local `kubectl` to the cluster (for EKS: `aws eks update-kubeconfig --region <region> --name <cluster>`; equivalents exist for GKE / AKS / DOKS). The agent confirms cluster-admin and that a LoadBalancer + default StorageClass are available, then walks the on-your-environment install guide and applies provider-specific workarounds (e.g. EKS LoadBalancer `internet-facing` patch) inline.

```text
Install OpenChoreo on my EKS cluster using AWS CLI. I already have kubectl access to the cluster.
```
