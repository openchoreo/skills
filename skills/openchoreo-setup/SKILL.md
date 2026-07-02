---
name: openchoreo-setup
description: Fresh install of OpenChoreo onto local k3d, an existing Kubernetes cluster (k3s/GKE/EKS/AKS/DOKS/self-managed), or across multiple clusters. Use when the user says "install OpenChoreo", "set up OpenChoreo on k3d", "bootstrap OpenChoreo on my cluster(s)", "spin up OpenChoreo locally", or "install the OpenChoreo platform".
metadata:
  version: "1.1.2"
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

## Pin the kube context first

Before running any `kubectl` / `helm`, establish **which context each command targets** and pass it explicitly — don't rely on the active context. Environments routinely carry several contexts (and the active one may be a placeholder or the wrong cluster), so an implicit context silently sends an install at the wrong place.

- Confirm the target up front: `kubectl config get-contexts`, and with the user settle which context is the install target (create/rename one if needed). For multi-cluster, settle one context per plane (cp / dp / op / wp).
- Pass it on **every** command: `kubectl --context=<ctx> …` and `helm --kube-context=<ctx> …`. In multi-cluster, name the plane's context on each command — never depend on "current" state carrying across steps.
- If a first `kubectl` call errors with an auth prompt / `EOF` / unreachable API, the active context is a dummy or wrong cluster — resolve the context before continuing, don't work around it.
