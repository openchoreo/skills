# OpenChoreo skills

A library of skills for working with OpenChoreo.

## About

[Skills](https://agentskills.io/) are a lightweight technique for adding relevant context to your agents. This repo contains skills for working with OpenChoreo on different use cases

These skills complement the [OpenChoreo MCP server](https://openchoreo.dev/docs/next/ai/mcp-servers/).

## Skills in this repo

| Skill | Description |
| :--- | :--- |
| [`openchoreo-developer`](skills/openchoreo-developer) | Skill for application developers shipping services on OpenChoreo. Covers deploying and updating Components / Workloads / ReleaseBindings, triggering builds, connecting components via endpoint dependencies, configuring env vars and secret references, promoting across Environments, and troubleshooting via status, events, and pod logs. |
| [`openchoreo-platform-engineer`](skills/openchoreo-platform-engineer) | Skill for platform engineers and operators running the OpenChoreo control plane. Covers authoring ComponentTypes / Traits / Workflows, creating Environments and DeploymentPipelines, registering DataPlanes / WorkflowPlanes / ObservabilityPlanes, configuring secret stores, identity, authorization, API gateway, alert channels, and Helm install / upgrade. |

## Installation

Browse and install skills with the `skills` CLI:

```sh
# Interactively browse and install skills.
npx skills add openchoreo/skills --list

# Install a specific skill (e.g., openchoreo-developer).
npx skills add openchoreo/skills --skill openchoreo-developer --global
```

## OpenChoreo MCP server

The skills in this repo are designed to be used alongside the OpenChoreo MCP servers, which gives your agent live access to the platform's resource graph.

See the [MCP server setup docs](https://openchoreo.dev/docs/next/ai/mcp-servers/) for instructions on
configuring it with your coding agent.

## Disclaimer

This is not an officially supported product. Use at your own risk.
