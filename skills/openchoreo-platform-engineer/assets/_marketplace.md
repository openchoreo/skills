## Prerequisites

- [OpenChoreo MCP server](https://openchoreo.dev/docs/ai/mcp-servers/) configured in your coding agent

## Use cases

Use this skill for platform-level work on OpenChoreo:

- Author component types, traits, and workflows for developers to use
- Bootstrap new tenant namespaces with their first project and environment
- Create environments and wire promotion pipelines across them
- Configure secret stores (Vault, AWS Secrets Manager, OpenBao) that back developer secrets
- Diagnose platform-side failures across the control plane, data planes, and workflow runs
- Run day-2 Helm upgrades of the OpenChoreo control plane

## Samples

### Onboard a new team with its own environment shape
A new team with specific environment needs. Have the agent provision the environments, wire up the deployment pipeline, and attach the team's project using the platform's defaults.

```text
We're onboarding a new team to the platform: orders-api. They need dev, staging, canary, and prod environments. Provision the environments, build out the deployment pipeline, and attach it to the team's project using the platform's default templates and policies.
```

### Author a CI workflow
Register a build workflow developers can pick when source-building a Component.

```text
Create a CI workflow go-buildpack that runs go test ./... and then builds an image with Buildpacks.
```

### Build a promotion pipeline with a manual gate
Wire several Environments into a DeploymentPipeline so developers can promote across them, with optional manual approvals.

```text
Build a dev → staging → prod deployment pipeline for team-payments, with prod requiring a manual gate.
```
