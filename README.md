# OpenChoreo skills

A library of skills for working with OpenChoreo.

## About

[Skills](https://agentskills.io/) are a lightweight technique for adding relevant context to your agents. This repo contains skills for working with OpenChoreo. Pick the one that matches your role and how you operate.

## Skills in this repo

| Skill | For | Prerequisites |
| :--- | :--- | :--- |
| [`openchoreo-developer`](skills/openchoreo-developer) | Application developers shipping services on OpenChoreo. | [OpenChoreo MCP server](https://openchoreo.dev/docs/ai/mcp-servers/) configured. |
| [`openchoreo-platform-engineer`](skills/openchoreo-platform-engineer) | Platform engineers running OpenChoreo. | [OpenChoreo MCP server](https://openchoreo.dev/docs/ai/mcp-servers/) configured; `kubectl` + Helm available. |
| [`openchoreo-platform-engineer-gitops`](skills/openchoreo-platform-engineer-gitops) | Platform engineers managing OpenChoreo via Git. | [`occ`](https://openchoreo.dev/docs/getting-started/cli-installation.md) configured against the cluster; [Flux CD](https://fluxcd.io/) in the cluster; `git`. |
| [`openchoreo-developer-gitops`](skills/openchoreo-developer-gitops) | Application developers working from an OpenChoreo GitOps repo. | [`occ`](https://openchoreo.dev/docs/getting-started/cli-installation.md) configured against the cluster; the repo already scaffolded; `git`. |

## Installation

Browse and install skills with the `skills` CLI:

```sh
# Interactively browse and install skills.
npx skills add openchoreo/skills --list

# Install a specific skill (e.g., openchoreo-developer).
npx skills add openchoreo/skills --skill openchoreo-developer
```
