---
name: openchoreo-setup
description: Fresh install of OpenChoreo onto local k3d, an existing Kubernetes cluster (k3s/GKE/EKS/AKS/DOKS/self-managed), or across multiple clusters. Use when the user says "install OpenChoreo", "set up OpenChoreo on k3d", "bootstrap OpenChoreo on my cluster(s)", "spin up OpenChoreo locally", or "install the OpenChoreo platform".
metadata:
  version: "0.1.0"
---

# OpenChoreo Setup

Bootstraps OpenChoreo onto Kubernetes. Two targets, each with a single-cluster and a multi-cluster path:

**Locally on k3d** (development / contributor workflow)
- Single cluster → [`./references/on-k3d-locally.md`](./references/on-k3d-locally.md)
- Multi-cluster (one cluster per plane) → [`./references/on-k3d-multi-cluster.md`](./references/on-k3d-multi-cluster.md)

**On your Kubernetes environment** (k3s, GKE, EKS, AKS, DOKS, Rancher Desktop, or self-managed)
- Single cluster → [`./references/on-your-environment.md`](./references/on-your-environment.md)
- Multi-cluster (full multi-cluster, hybrid, or multi-region) → [`./references/multi-cluster.md`](./references/multi-cluster.md)

Ask the user which target and topology if they haven't said. Then load the matching reference and follow it end to end — it owns the choice-capture, version resolution, fetch, walk, and report flow for that path.
