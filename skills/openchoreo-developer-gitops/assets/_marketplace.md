## Prerequisites

- [`occ` CLI](https://openchoreo.dev/docs/getting-started/cli-installation.md) configured against the OpenChoreo cluster the GitOps repo manages
- An OpenChoreo GitOps repo cloned locally — run the skill from inside that repo. (If you don't have one yet, use the `openchoreo-platform-engineer-gitops` skill to scaffold one first.)

## Use cases

Use this skill for application-developer work in an OpenChoreo GitOps repo:

- Onboard a Component using pre-built images or source builds, with the build pipeline opening pull requests against the GitOps repo
- Configure the runtime contract — image, environment variables, files, secrets, endpoints
- Attach platform-authored traits to add capabilities to a Component
- Connect Components together so the platform injects connection details
- Promote releases across Environments — single Component or bulk (project / namespace-wide)
- Apply per-environment overrides on a release (replicas, resources, env vars, trait config)
- Roll back to a previous release; soft-undeploy
- Verify the cluster reflects what's in Git after a merge
