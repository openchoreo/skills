---
name: openchoreo-setup
description: Fresh install of OpenChoreo onto local k3d or an existing Kubernetes cluster (k3s/GKE/EKS/AKS/DOKS/self-managed). Use when the user says "install OpenChoreo", "set up OpenChoreo on k3d", "bootstrap OpenChoreo on my cluster", "spin up OpenChoreo locally", or "install the OpenChoreo platform".
metadata:
  version: "0.1.0"
---

# OpenChoreo Setup

Bootstraps OpenChoreo onto a Kubernetes cluster. Two paths, each with its own self-contained playbook:

- **Local k3d** → follow [`./references/on-k3d-locally.md`](./references/on-k3d-locally.md)
- **Existing Kubernetes cluster** (k3s, GKE, EKS, AKS, DOKS, Rancher Desktop, or self-managed) → follow [`./references/on-your-environment.md`](./references/on-your-environment.md)

Ask the user which target if they haven't said. Then load the matching reference and follow it end to end — it owns the choice-capture, version resolution, fetch, walk, and report flow for that target.
