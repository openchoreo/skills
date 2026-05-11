# Recipe — Promote a release to the next Environment

`ComponentRelease` is immutable. Promotion = creating a new `ReleaseBinding` for the next Environment, referencing the same `ComponentRelease`. `occ releasebinding generate` handles it.

For promoting multiple components at once (project-wide or namespace-wide), see [`bulk-promote.md`](./bulk-promote.md).

## Preconditions

- The component has at least one ComponentRelease in the repo, and a ReleaseBinding in the source environment (typically `development`) that's `Ready=True`.
- The target environment exists in the namespace's DeploymentPipeline. Confirm:
  ```bash
  occ deploymentpipeline get <pipeline> -n <ns>
  # spec.promotionPaths[] lists the env ordering
  ```

## Steps

### 1. Identify the chain

```bash
occ deploymentpipeline get standard -n default
```

Look at `spec.promotionPaths[]`. Typical:

```yaml
promotionPaths:
  - sourceEnvironmentRef: { name: development }
    targetEnvironmentRefs: [{ name: staging }]
  - sourceEnvironmentRef: { name: staging }
    targetEnvironmentRefs: [{ name: production }]
```

To promote dev → staging, the next target is `staging`. To promote staging → production, target is `production`.

### 2. Generate the ReleaseBinding for the next env

```bash
occ releasebinding generate \
  --mode file-system --root-dir <repo> \
  --project <project> --component <component> \
  --target-env staging --use-pipeline standard \
  --component-release <release-name>             # optional; defaults to latest
```

`--component-release` is the safer choice in GitOps — explicitly pin the release name so the promotion is deterministic and reproducible. Without it, the latest release in the repo is used (which can change if a new build lands between commands).

Writes `release-bindings/<component>-staging.yaml`.

### 3. Commit, PR, wait

```bash
git checkout -b release/<component>-promote-staging-$(date +%Y%m%d-%H%M%S)
git add namespaces/<ns>/projects/<project>/components/<component>/release-bindings/
git commit -s -m "Promote <component> to staging (release <release-name>)"
git push origin HEAD                              # only after user confirmation
gh pr create --fill                               # only after user confirmation
```

Wait for merge.

### 4. Verify

```bash
flux get kustomizations -A
occ releasebinding get <component>-staging -n <ns>
# Watch: ReleaseSynced → ResourcesReady → Ready

# Cross-check: same releaseName as the dev binding?
occ releasebinding get <component>-development -n <ns> | grep releaseName
occ releasebinding get <component>-staging -n <ns> | grep releaseName
```

For public-facing services, curl `status.endpoints[]` to confirm.

## Rollback

Bind the previous ComponentRelease to the same Environment:

```bash
occ releasebinding generate \
  --mode file-system --root-dir <repo> \
  --project <project> --component <component> \
  --target-env staging --use-pipeline standard \
  --component-release <previous-release-name>
```

This overwrites `release-bindings/<component>-staging.yaml` to point at the older release. Commit + PR + reconcile. OpenChoreo redeploys the previous release.

Alternatively, edit the file directly:

```yaml
# release-bindings/<component>-staging.yaml
spec:
  releaseName: <previous-release-name>            # change this
```

Both produce the same result. The `occ` path is safer (matches generator semantics; less typo surface).

## Soft-undeploy

To remove a component from an environment without deleting the binding (so the release name is preserved for fast re-deploy):

Edit the ReleaseBinding's `spec.state` to `Undeploy`:

```yaml
spec:
  environment: staging
  state: Undeploy                                  # was Active (default)
  owner:
    componentName: <component>
    projectName: <project>
  releaseName: <release-name>
```

Commit + PR + reconcile. The platform tears down the rendered K8s resources on the DataPlane but keeps the binding record. To re-deploy, flip back to `Active`.

For hard delete (remove the binding entirely), delete the file in Git and let Flux prune.

## Variants

### Promote to multiple targets from one source

If the pipeline forks (e.g. `staging → [production-us, production-eu]`), `occ releasebinding generate` produces one binding per call. Loop:

```bash
for ENV in production-us production-eu; do
  occ releasebinding generate \
    --mode file-system --root-dir <repo> \
    --project <project> --component <component> \
    --target-env $ENV --use-pipeline standard \
    --component-release <release-name>
done
```

Commit all in one PR (one branch, one `gh pr create`).

### Override during promotion

A ReleaseBinding for staging may need different replicas / resources / env vars than dev. Add overrides under `componentTypeEnvironmentConfigs`, `traitEnvironmentConfigs`, or `workloadOverrides`. See [`override-per-environment.md`](./override-per-environment.md).

`occ releasebinding generate` writes a base binding without overrides. Edit the file post-generation to add them.

### One PR per env (safer)

For shared / production repos, one PR per environment is the safer default — reviewer attention per env, clean rollback, smaller blast radius. The recipe above produces one PR per call.

For sandboxes / dev work, bundling many promotions in one PR is fine — pick per the repo profile.

## Gotchas

- **Pin `--component-release` for deterministic promotions.** Without it, `releasebinding generate` picks the latest `ComponentRelease` at run time — fine for dev, risky for staging / production where you want to bind a specific known-good build.
- **`--target-env` must match an Environment that exists.** If the namespace doesn't have a `staging` env, the binding sits at `Ready=False`.
- **`--use-pipeline` is required with `--all` or when the Project's pipeline ref is ambiguous.** Always set explicitly.
- **ReleaseBindings are env-specific.** One per env per component. The file name convention is `<component>-<env>.yaml`; overwriting an existing one (e.g. rollback) is normal and intended.
- **Cross-env config drift.** Two different `componentTypeEnvironmentConfigs` per env is by design. If both envs should look the same except for env-specific endpoints, share the configs via the ComponentType defaults rather than duplicating in every binding.

## Related

- [`bulk-promote.md`](./bulk-promote.md) — promote many components at once
- [`override-per-environment.md`](./override-per-environment.md) — per-env replicas, resources, env vars
- [`onboard-component-byo.md`](./onboard-component-byo.md), [`onboard-component-source-build.md`](./onboard-component-source-build.md)
- [`../concepts.md`](../concepts.md) *ReleaseBinding*, *ComponentRelease*
