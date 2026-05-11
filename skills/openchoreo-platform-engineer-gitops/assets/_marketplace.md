## Prerequisites

- [`occ` CLI](https://openchoreo.dev/docs/getting-started/cli-installation.md) configured against your OpenChoreo cluster
- A Git host to push the GitOps repo to (GitHub / GitLab / Bitbucket / self-hosted)
- Other tools (`kubectl`, `flux` CLI, Flux running in the cluster) are needed only for scaffolding and verification — the skill will install / install-guide Flux when it's missing

## Use cases

Use this skill for platform-engineer GitOps work on OpenChoreo:

- Scaffold a fresh GitOps repo, or move an already-running OpenChoreo cluster onto GitOps
- Wire Flux CD with the documented `Kustomization` chain
- Capture cluster-side platform resources into Git so Flux can own them (with optional cluster-side cleanup once reconciled)
- Install the GitOps-mode build-and-release Workflows (`docker-gitops-release` etc.) plus their Argo `ClusterWorkflowTemplate`s — the vanilla CI workflows aren't GitOps-compatible, the skill replaces them automatically
- Author ComponentTypes, Traits, Workflows, Environments, DeploymentPipelines, SecretReferences, AuthzRoles, AlertRules, NotificationChannels via Git
- Verify Flux reconciliation; recover from drift when the cluster and Git diverge

## Samples

### Scaffold a fresh GitOps repo with the standard defaults

Start a GitOps repo from scratch and bring in the shipped Project / Environments / DeploymentPipeline / ClusterComponentTypes / ClusterTraits plus the GitOps-mode build-and-release workflows.

> Needs an OpenChoreo cluster running with no default resources installed yet. If you don't have one, use the `openchoreo-setup` skill first (skip its default-resources step).

```text
Scaffold a GitOps repo in this directory for my cluster, install the standard defaults, push to my GitHub, and wire Flux against it.
```

Once the repo is wired, hand the agent an off-the-shelf microservices app and deploy it into the same cluster using the published images.

```text
Now deploy https://github.com/GoogleCloudPlatform/microservices-demo into this cluster using their already-published remote images.
```

### Move a running cluster onto GitOps

The agent inventories the cluster, surfaces each platform-resource category, and lets you decide per category: capture into Git, replace with defaults, or leave on the cluster.

```text
Set up GitOps for this cluster. Move the platform resources and the running projects into a new GitOps repo, wire Flux against it, and replace the vanilla CI workflows with the GitOps-mode ones.
```
