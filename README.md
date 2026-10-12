# OpenChoreo skills

A library of skills for working with OpenChoreo.

## About

[Skills](https://agentskills.io/) are a lightweight technique for adding relevant context to your agents. This repo contains skills for working with OpenChoreo. Pick the one that matches your role and how you operate.

## Skills in this repo

| Skill | For | Prerequisites |
| :--- | :--- | :--- |
| [`openchoreo-setup`](skills/openchoreo-setup) | Installing OpenChoreo onto Kubernetes — local k3d, a hosted cluster (k3s/GKE/EKS/AKS/DOKS/self-managed), or a multi-cluster topology. | `helm` ≥ 3, `kubectl`; `k3d` for the local path; cluster credentials for hosted targets. |
| [`migrate-to-openchoreo`](skills/migrate-to-openchoreo) | Planning a migration of an existing app (Helm chart, Kustomize overlay, Docker Compose, or raw Kubernetes YAML) onto OpenChoreo. Plans only — never applies. | Node ≥ 18 for the preview server; the renderer for your source (`helm`, `kustomize` / `kubectl kustomize`, or `kompose`); a browser. |
| [`openchoreo-developer`](skills/openchoreo-developer) | Application developers shipping services on OpenChoreo. | [OpenChoreo MCP server](https://openchoreo.dev/docs/ai/mcp-servers/) configured. |
| [`openchoreo-platform-engineer`](skills/openchoreo-platform-engineer) | Platform engineers running OpenChoreo. | [OpenChoreo MCP server](https://openchoreo.dev/docs/ai/mcp-servers/) configured; `kubectl` + Helm available. |
| [`openchoreo-developer-gitops`](skills/openchoreo-developer-gitops) | Application developers working from an OpenChoreo GitOps repo. | [`occ`](https://openchoreo.dev/docs/getting-started/cli-installation.md) configured against the cluster; the repo already scaffolded; `git`. |
| [`openchoreo-platform-engineer-gitops`](skills/openchoreo-platform-engineer-gitops) | Platform engineers managing OpenChoreo via Git. | [`occ`](https://openchoreo.dev/docs/getting-started/cli-installation.md) configured against the cluster; [Flux CD](https://fluxcd.io/) in the cluster; `git`. |

## Installation

Browse and install skills with the `skills` CLI:

```sh
# Interactively browse and install skills.
npx skills add openchoreo/skills --list

# Install a specific skill (e.g., openchoreo-developer).
npx skills add openchoreo/skills --skill openchoreo-developer
```

### Agent Plugins

This repo is also an [Agent Plugins](https://agent-plugins.org/) package: a root [`plugin.json`](plugin.json) plus the skills under `skills/`. Clients that support the standard can install the whole repo as one plugin from `https://github.com/openchoreo/skills`; see your client's documentation for how.

The plugin ships skills only. Skills that use the OpenChoreo MCP server still need it configured in your client, as described in [Configuring MCP Servers with AI Assistants](https://openchoreo.dev/docs/ai/mcp-servers/).

## Support

Report issues at [github.com/openchoreo/skills/issues](https://github.com/openchoreo/skills/issues), or ask in [#openchoreo](https://cloud-native.slack.com/channels/openchoreo) on the CNCF Slack ([join here](https://slack.cncf.io/)).

## Privacy

These skills are instructions and helper scripts that run locally in your coding agent. They collect no data and send nothing to OpenChoreo maintainers. Your agent talks to the OpenChoreo installation you configure, and some helper scripts download public documentation from `openchoreo.dev` and `raw.githubusercontent.com`. OpenChoreo is a CNCF project, covered by the [Linux Foundation Privacy Policy](https://www.linuxfoundation.org/legal/privacy-policy).
