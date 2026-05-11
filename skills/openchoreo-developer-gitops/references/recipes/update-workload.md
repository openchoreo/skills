# Recipe — Update a Workload

Changes to image, env vars, file mounts, endpoints, or dependencies after the initial onboard. Mechanics differ between BYO and source-build, and within source-build between Path A (`workload.yaml` in source repo) and Path B (Workload CR in GitOps repo).

## BYO

Edit the Workload CR directly in the GitOps repo:

```bash
# namespaces/<ns>/projects/<project>/components/<component>/workload.yaml
# Edit container.image, env, files, endpoints, etc.
```

Then regenerate the ComponentRelease (it's a new snapshot since the Workload changed):

```bash
occ componentrelease generate \
  --mode file-system --root-dir <repo> \
  --project <project> --component <component>
```

If `Component.spec.autoDeploy: true`, the controller will auto-create a ReleaseBinding for the root env once the release exists. Otherwise generate it:

```bash
occ releasebinding generate \
  --mode file-system --root-dir <repo> \
  --project <project> --component <component> \
  --target-env development --use-pipeline standard
```

PR with all three changes (Workload + new release file + updated/new ReleaseBinding):

```bash
git checkout -b release/<component>-update-$(date +%Y%m%d-%H%M%S)
git add namespaces/<ns>/projects/<project>/components/<component>/
git commit -s -m "Component <component>: update Workload"
git push origin HEAD
gh pr create --fill
```

After merge: walk verification ladder (see [`verify-and-debug.md`](./verify-and-debug.md)).

## Source-build — Path A (`workload.yaml` in source repo)

The build's `generate-workload` step full-PUTs the Workload from the descriptor. Iteration:

1. Edit `<src-repo>/<appPath>/workload.yaml` (add an env var, change an endpoint).
2. Commit + push to the source repo (with user approval).
3. Trigger a rebuild — `occ component workflow run <component>` or rely on `autoBuild: true` + webhook.
4. Wait for the build's PR on the GitOps repo. It contains the updated Workload + new ComponentRelease + new ReleaseBinding (for the root env if `autoDeploy: true`).
5. Review and merge the PR.
6. Wait for Flux to reconcile.

> **Any direct edits to non-image fields on the cluster Workload (kubectl or otherwise) are overwritten on the next rebuild.** Don't edit the GitOps-repo Workload directly on Path A — it gets regenerated.

For image-only changes (just a new build with no descriptor change), the rebuild produces the same Workload spec with a new `container.image`. No source-repo edits needed if `autoBuild: true` and a webhook is set.

## Source-build — Path B (Workload CR in GitOps repo)

The build only patches `container.image` on rebuild; other fields persist. Iteration:

1. Edit `namespaces/<ns>/projects/<project>/components/<component>/workload.yaml` in the GitOps repo (add an env var, change an endpoint).
2. Regenerate the ComponentRelease:
   ```bash
   occ componentrelease generate \
     --mode file-system --root-dir <repo> \
     --project <project> --component <component>
   ```
3. Generate / regenerate ReleaseBindings as needed.
4. PR, merge, reconcile.

For image-only changes, trigger the build normally (it produces a Workload-only patch + new release + ReleaseBinding via PR). Your edits to other fields persist.

## Field-name reminders (descriptor vs CR)

| Field        | Workload CR                | Workload descriptor           |
| ------------ | -------------------------- | ----------------------------- |
| Env vars     | `container.env[].key`      | `configurations.env[].name`   |
| File mounts  | `container.files[].key`    | `configurations.files[].name` |
| Endpoints    | `endpoints` (map)          | `endpoints[]` (list with `name` field) |

Mixing the two in the same file is a parse error or worse — admission accepts the CR shape on the Workload CR, but the build rewrites the file every rebuild on Path A.

## Adding a `workload.yaml` to a source-build component that's been on Path B

**One-way and destructive.** The first rebuild that finds the new `workload.yaml` will full-PUT from it, **overwriting all your GitOps-repo edits**. Migrate cleanly:

1. Dump the current Workload from the GitOps repo (or `occ workload get <component>-workload -n <ns>`).
2. Translate to descriptor shape (the field names above).
3. Commit `workload.yaml` to the source repo at `<appPath>/workload.yaml`.
4. Trigger a rebuild.
5. Review the build's PR — verify it produces the same Workload spec you had before.
6. Merge.

Going forward, the source repo is the source of truth for the Workload contract.

## What doesn't go in the Workload

- **Replicas, resource limits, imagePullPolicy** — per-environment, on the ReleaseBinding under `componentTypeEnvironmentConfigs`.
- **Trait parameters** — on the Component.
- **Trait `environmentConfigs`** — per-env, on the ReleaseBinding under `traitEnvironmentConfigs[<instanceName>]`.
- **Anything that differs per env** — on the ReleaseBinding under `workloadOverrides` (env vars, files).

Putting these on the Workload puts them everywhere; the override paths above let them vary per env.

## Gotchas

- **Forgetting to regenerate the ComponentRelease after a Workload edit.** Flux applies the Workload change, but if no new ComponentRelease points at the new Workload state, the existing ReleaseBindings still bind to the old snapshot. Always regenerate the release after a Workload change in GitOps mode.
- **Updating an immutable field** — `Workload.spec.owner` (projectName + componentName), `Component.spec.componentType.name` after a release was generated. The admission webhook rejects.
- **PR conflict on the GitOps repo** when two concurrent rebuilds run for the same component on Path A. Merge or rebase in order.
- **Image tag reuse.** If `container.image` is the same tag as before, the Workload diff is empty and no new ComponentRelease should be needed. Force-regenerate only if the underlying registry pushed a new manifest under the same tag (treat that as an anti-pattern though — pin tags to immutable references).

## Related

- [`onboard-component-byo.md`](./onboard-component-byo.md), [`onboard-component-source-build.md`](./onboard-component-source-build.md)
- [`configure-workload.md`](./configure-workload.md)
- [`override-per-environment.md`](./override-per-environment.md) — per-env values stay off the Workload
- [`promote.md`](./promote.md) — bind the new release to the next env
