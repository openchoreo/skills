## Prerequisites

- [OpenChoreo MCP server](https://openchoreo.dev/docs/ai/mcp-servers/) configured in your coding agent

## Use cases

Use this skill for application-level work on OpenChoreo:

- Onboard simple applications to OpenChoreo using available component types and traits
- Deploy components from pre-built images or source builds
- Connect components together and configure env vars, files, and secrets
- Attach platform-authored traits to add capabilities to a component
- Trigger builds and follow their progress
- Promote releases across environments with per-environment overrides, undeploy, or roll back
- Diagnose unhealthy deploys with status, events, and pod logs
- Browse what the platform offers — component types, traits, workflows, environments

## Samples

### Onboard the GCP microservices demo app
Hand the agent the GCP microservices demo app and have it figure out how each service maps to OpenChoreo concepts (component types, traits, environments), then onboard each one end-to-end.

```text
Deploy github.com/GoogleCloudPlatform/microservices-demo into OpenChoreo using their already-published images.
```

### Scaffold an app and deploy from source
Let the agent get creative: build a live audience Q&A app, push to GitHub, deploy each component to OpenChoreo from source.

```text
Build a live audience Q&A app (join by code, submit + upvote questions, host moderates). Push it to my GitHub as a public repo, then deploy each component to OpenChoreo from source.
```

Once the first deploy is healthy, promote it forward.

```text
Promote it to the next environment.
```

Make some changes and deploy them to dev.

```text
Implement a dark theme and push it.
```
