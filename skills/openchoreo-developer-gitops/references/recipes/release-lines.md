# Recipe — Run a release line via Git

A **release line** runs another version of a Component side by side with it in the same environments, for example a `next` line built from another branch next to the stable build. Each line has its own Workload, ComponentReleases and ReleaseBindings, all in Git, and is promoted and rolled back on its own. **v1.4+ only.** Check that the cluster has release lines (`occ component releaseline --help` works, or `kubectl get crd releaselines.openchoreo.dev`). Without them, use a second Component instead and tell the user why.

Concepts: [`../concepts.md`](../concepts.md) *Release lines*.

## Repo layout for a line

Everything stays in the component's directory, next to the main line's files:

```text
components/<component>/
├── component.yaml                                   # the main line = the Component itself
├── workload.yaml                                    # main line's Workload  (<component>-workload)
├── release-line-<line>.yaml                         # the ReleaseLine (hand-authored)
├── workload-<line>.yaml                             # the line's Workload   (<component>-<line>-<hash>-workload) — occ writes this file name
├── releases/<component>-<line>-<hash>-<date>-<n>.yaml           # the line's ComponentReleases
└── release-bindings/<component>-<line>-<hash>-<env>.yaml        # the line's ReleaseBindings
```

`<hash>` is derived from the component and line names. The `occ` generators compute it, so never type it by hand. Use the generated names, or read them back with `occ component releaseline get`.

## Steps

### 1. Author the ReleaseLine

No generator exists. The shape is below. For the full schema, use `kubectl explain releaseline.spec --recursive` against the control plane (stable docs may not have a ReleaseLine page yet). Shape:

```yaml
apiVersion: openchoreo.dev/v1alpha1
kind: ReleaseLine
metadata:
  name: greeter-next                 # unique in the namespace, across ALL components
  namespace: <ns>
  annotations:
    openchoreo.dev/description: "Preview line, built from the release-next branch"
spec:
  owner:                             # immutable
    projectName: <project>
    componentName: greeter
  # autoDeploy: false                # optional; overrides the Component's autoDeploy for this line
  workflow:                          # source-build: deep-merged onto Component.spec.workflow.parameters
    parameters:
      repository:
        revision:
          branch: release-next       # or commit: <sha> to pin (pushes then don't move it)
  # parameters: { ... }              # deep-merged onto Component.spec.parameters (maps merge, scalars/lists replace)
  # traits:                          # merged by kind + name + instanceName; a new one is appended
  #   - kind: ClusterTrait
  #     name: health-probes
  #     instanceName: health
  #     parameters: { readiness: { enabled: true } }
```

- **The name is a namespace-wide object name.** Two components can't both have a line called `next`, so prefix it with the component unless the user picked a name. `main` and `default` are reserved.
- **The line inherits the Component** (parameters, traits, workflow parameters) and overrides only what it sets. The ComponentType and the workflow kind/name are shared.
- **The line doesn't inherit the main line's Workload.** It needs its own (step 2).

Save as `components/<component>/release-line-<line>.yaml`.

### 2. Give the line a Workload

**BYO** — generate it with the line's image. `occ` names it `<component>-<line>-<hash>-workload` and writes `workload-<line>.yaml` next to the component:

```bash
occ workload create --mode file-system --root-dir <repo> \
  --project <project> --component greeter --release-line greeter-next \
  --image ghcr.io/acme/greeter:2.0.0-rc1 --descriptor workload.yaml
```

**Source-build** — after the ReleaseLine is merged and reconciled, trigger the line's build. The PE's GitOps build workflow must forward the release line, or the build overwrites the main line's `workload.yaml`. Check the first run's PR before trusting it:

```bash
occ component workflow run greeter --release-line greeter-next -n <ns>
```

Its PR should touch `workload-<line>.yaml` and the line's release and binding files, not the main line's. If it touched the main line's files, close it and escalate: the Workflow needs release-line support (PE skill: `author-workflow.md` *Build a release line's files*).

### 3. Release and bind the line

For a BYO line, or after hand-editing the line's Workload, generate the release and the first binding. `--release-line` requires `--component`:

```bash
occ componentrelease generate --mode file-system --root-dir <repo> \
  --project <project> --component greeter --release-line greeter-next

occ releasebinding generate --mode file-system --root-dir <repo> \
  --project <project> --component greeter --release-line greeter-next \
  --target-env <first env> --use-pipeline <pipeline>
```

The release generator reads the ReleaseLine file from the repo to apply the line's overrides, so `release-line-<line>.yaml` (step 1) must exist locally before you run it.

### 4. Commit, PR, verify

Branch `release/<component>-<line>-<ts>`, paths `namespaces/<ns>/projects/<project>/components/<component>/`, message `"Add release line <line> to <component>"`. Canonical flow in [`../authoring.md`](../authoring.md) *Git workflow*. After merge:

```bash
flux get kustomizations -A
occ component releaseline list greeter -n <ns>          # main first, then each line, per env: release + ready
occ component releaseline get greeter greeter-next -n <ns>
occ releasebinding get <component>-<line>-<hash>-development -n <ns>   # ReleaseSynced → ResourcesReady → Ready; URLs in status.endpoints[]
```

The line has its own URLs, because its routes are named from `<component>-<line>-<hash>`. Take them from the binding, not by guessing.

## Promote a line

Same as [`promote.md`](./promote.md), plus `--release-line`. Only that line's binding is written:

```bash
occ releasebinding generate --mode file-system --root-dir <repo> \
  --project <project> --component greeter --release-line greeter-next \
  --target-env staging --use-pipeline <pipeline> \
  --component-release <release the line runs in development>
```

Without `--component-release`, the generator binds the release the line runs in the previous environment. In GitOps, nothing else enforces pipeline order: the API's promotion check doesn't apply to bindings Flux applies, so a pinned `--component-release` is taken as given. Pin only a release the line already runs in the source environment. The release must belong to the line: a binding to another line's release fails to reconcile.

## Roll a line back

Repoint the line's binding at an earlier release of the same line (`--component-release <older>` as above, or edit `spec.releaseName`). Prefer rolling back in pipeline order, first environment first, so no environment runs a release its predecessor doesn't. With `autoDeploy` (the Component's, or the line's), the controller soon binds the line's latest release to the first environment again. To hold a rollback, set `spec.autoDeploy: false` on the ReleaseLine in the same PR, and remove it once a fixed build lands.

## Delete a line

Delete `release-line-<line>.yaml`, `workload-<line>.yaml` and the line's release and binding files in one PR, and let Flux prune. The controller undeploys the line from every environment. The main line and other lines keep running. Confirm with the user first.

## Gotchas

- **`--all` / `--project` generate for every line.** Bulk `componentrelease generate` and `releasebinding generate` cover each component's main line **and** all its lines. Use `--component --release-line` to touch one line. If a component's main line has no Workload, it's released through its lines only.
- **A line's binding goes `ReleaseSynced=False` with `ReleaseLineNameCollision` or `ReleaseLinePodLabelOverlap`.** The ComponentType or a Trait isn't release-line-safe. Nothing is wrong with the line, and the main line keeps running. Escalate to the platform side.
- **`ReleaseLineNotFound`** means the binding names a line that isn't in the cluster yet (unmerged, or misspelled). A line of another component gives `InvalidReleaseConfiguration` instead.
- **Main-line Workload edits don't reach a line.** Repeat them in `workload-<line>.yaml`. For a source-built line, put them in that branch's `workload.yaml`, because each build replaces the line's Workload from it.
- **Logs and exec default to the main line.** Use `occ component logs <component> --release-line <line>` (or `--all-release-lines`) and `occ component exec <component> --release-line <line>`.

## Related

- [`promote.md`](./promote.md), [`bulk-promote.md`](./bulk-promote.md) — the same mechanics on the main line, and bulk behavior
- [`connect-components.md`](./connect-components.md) — depending on a specific line
- [`verify-and-debug.md`](./verify-and-debug.md)
