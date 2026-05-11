# Authoring

How application CRD shapes get into Git. `occ` ships four file-mode generators that do most of the heavy lifting; everything else hand-authored from `llms.txt` references or templated from cluster.

## The four `occ` file-mode generators

`--mode file-system` is required (the default `api-server` mode applies to the cluster directly). Run `occ <command> -h` for the full flag list; reference: <https://openchoreo.dev/docs/reference/cli-reference.md>.

### `occ component scaffold COMPONENT_NAME`

Generates a Component YAML from a (Cluster)ComponentType + optional (Cluster)Traits + optional (Cluster)Workflow. **Requires login** — reads the live cluster schemas to materialise the spec.

Flags:

- `--componenttype <workloadType>/<name>` / `--clustercomponenttype <workloadType>/<name>` — mutually exclusive
- `--traits <csv>` / `--clustertraits <csv>` — comma-separated
- `--workflow <name>` / `--clusterworkflow <name>`
- `-n, --namespace <ns>`, `-p, --project <project>`
- `-o, --output-file <path>` — writes to a file; without, prints to stdout
- `--skip-comments` — minimal output (no section headers / field descriptions)
- `--skip-optional` — required fields only

Example:

```bash
occ component scaffold greeter-service \
  --namespace default --project doclet \
  --clustercomponenttype deployment/service \
  --clustertraits observability-alert-rule \
  --clusterworkflow docker-gitops-release \
  -o namespaces/default/projects/doclet/components/greeter-service/component.yaml
```

Open the output file and fill in any placeholders the scaffold left (typically inside `spec.parameters` and trait `parameters` blocks).

### `occ workload create`

Synthesises a Workload CR from a workload-descriptor file + an image. For BYO components.

Flags:

- `--image <ref>` — required for BYO
- `--descriptor <path>` — optional; without it the Workload has only the image
- `-n, --namespace <ns>`, `-p, --project <p>`, `-c, --component <c>`
- `--mode file-system`, `--root-dir <gitops-repo>`
- `--name <name>` — defaults to `{component}-workload`
- `-o yaml`, `--dry-run`

```bash
occ workload create \
  --mode file-system --root-dir . \
  --project doclet --component greeter-service \
  --image ghcr.io/<org>/greeter:v1.2.3 \
  --descriptor namespaces/default/projects/doclet/components/greeter-service/workload.yaml
```

Writes to `namespaces/<ns>/projects/<project>/components/<component>/workload.yaml` (the Workload CR — note: same file name as a workload-descriptor mirror, since they don't both exist in this directory together for BYO). For source-build, the build pipeline runs this step internally; **don't commit a Workload CR for source-build Components** unless you're using Path B (see [`recipes/onboard-component-source-build.md`](./recipes/onboard-component-source-build.md)).

### `occ componentrelease generate`

Generates an immutable `ComponentRelease` snapshot from Component + Workload + ComponentType + Traits.

Flags:

- `--all` / `--project <p>` / `--component <c>` (require `--project`) — one of these
- `--name <release-name>` — only with `--component`; otherwise auto-generated (`<component>-<date>-<n>`)
- `--mode file-system`, `--root-dir`, `--output-path` (override default)
- `--dry-run`

```bash
occ componentrelease generate \
  --mode file-system --root-dir . \
  --project doclet --component greeter-service
```

Writes `namespaces/<ns>/projects/<project>/components/<component>/releases/<release-name>.yaml`. The auto-generated name follows `<component>-<YYYYMMDD>-<n>`.

### `occ releasebinding generate`

Generates a ReleaseBinding that binds a ComponentRelease to a target Environment.

Flags:

- `--all` / `--project <p>` / `--component <c>` (require `--project`)
- `-e, --target-env <env>` — required
- `--use-pipeline <pipeline>` — required with `--all`; optional with `--project` / `--component` (defaults to the Project's pipeline)
- `--component-release <name>` — only valid with `--project` + `--component`; otherwise defaults to the latest
- `--mode file-system`, `--root-dir`, `--output-path`, `--dry-run`

```bash
# Single component to a specific env
occ releasebinding generate \
  --mode file-system --root-dir . \
  --project doclet --component greeter-service \
  --target-env staging --use-pipeline standard
```

Writes `namespaces/<ns>/projects/<project>/components/<component>/release-bindings/<component>-<env>.yaml`. One ReleaseBinding per call — loop along the DeploymentPipeline for promotion.

## `release-config.yaml`

Optional file at the GitOps repo root. Overrides the default output directories `componentrelease generate` and `releasebinding generate` use per project / component. Schema:

```yaml
apiVersion: openchoreo.dev/v1alpha1
kind: ReleaseConfig
componentReleaseDefaults:
  defaultOutputDir: namespaces/<ns>/projects/<project>/components/<component>/releases
  projects:
    <project-name>:
      defaultOutputDir: namespaces/<ns>/projects/<project>/releases
      components:
        <component-name>: namespaces/<ns>/projects/<project>/components/<component>/releases
releaseBindingDefaults:
  defaultOutputDir: namespaces/<ns>/projects/<project>/components/<component>/release-bindings
  # Same project/component structure as above.
```

Resolution priority: explicit per-component → per-project default → top-level default → (fallback) repo-index resolver matching the documented layout.

When absent, paths are inferred from the repo index per the documented layout. The PE skill (or the user) sets it up during scaffolding — this skill consumes whatever's there.

## Everything else from `llms.txt`

For kinds without a file-mode generator (Project, ReleaseBinding overrides, dependency wiring on Workload, hand-authored Components for tricky cases), hand-author from API references.

1. **Capture the running `occ` minor** — parse `Client.Version` from `occ version`. Derive `$OCC_MINOR` (e.g. `v1.0.x`).
2. **Match against `llms.txt`** — `https://openchoreo.dev/llms.txt`. If its header version differs from `$OCC_MINOR`, fetch `https://openchoreo.dev/llms-$OCC_MINOR.txt`. Past minors live at `llms-v<minor>.x.txt`; bleeding edge is `llms-next.txt`.
3. **API reference URLs** follow:
   ```
   https://openchoreo.dev/docs/reference/api/<scope>/<kind>.md
   ```
   For app-level kinds, `<scope>` is `application` (Project, Component, Workload, WorkflowRun) or `platform` (ReleaseBinding) or `runtime` (ComponentRelease — controller-generated; never hand-author).
4. **Compose YAML** from the page's field tables. Cite the page in a comment:
   ```yaml
   # shape: https://openchoreo.dev/docs/reference/api/application/component.md (occ v1.0.x)
   apiVersion: openchoreo.dev/v1alpha1
   kind: Component
   ...
   ```
5. **Or template from a live instance.** When a similar resource exists, `occ <kind> get <name>` prints YAML — strip `status:` and `metadata.managedFields:`, edit, save.

## Repo paths (application resources)

| Kind                | Path                                                                                  |
| ------------------- | ------------------------------------------------------------------------------------- |
| `Project`           | `namespaces/<ns>/projects/<project>/project.yaml`                                     |
| `Component`         | `namespaces/<ns>/projects/<project>/components/<component>/component.yaml`            |
| `Workload`          | `namespaces/<ns>/projects/<project>/components/<component>/workload.yaml`             |
| `ComponentRelease`  | `namespaces/<ns>/projects/<project>/components/<component>/releases/<release>.yaml`   |
| `ReleaseBinding`    | `namespaces/<ns>/projects/<project>/components/<component>/release-bindings/<component>-<env>.yaml` |

`occ` file-mode generators write to these paths by default. The layout is fixed at repo-scaffold time; if you need to override per project / component, use a `release-config.yaml` at the repo root (see *`release-config.yaml`* above).

## Sequencing inside one PR

OpenChoreo controllers reconcile based on content, not order — so co-committed resources are fine. Common pairings:

- New Project + first Component(s) + Workload(s) + ComponentRelease + ReleaseBinding — all in one PR for a clean "onboard a service" landing.
- Component + Workload changes that affect both → bump both in the same PR; regenerate ComponentRelease + ReleaseBindings.
- Promotion to multiple envs → one ReleaseBinding file per env, all in one PR (the safer default), or one PR per env (most explicit).

For build-and-release workflow-driven flows, the PR is produced *by* the workflow — you don't compose it by hand.

## Git workflow

| Scope                                  | Branch convention                       |
| -------------------------------------- | --------------------------------------- |
| Onboarding a new Component             | `release/<component>-<ts>`              |
| Updating a Component / Workload        | `release/<component>-<ts>`              |
| Single-env promotion (one component)   | `release/<component>-promote-<env>-<ts>` |
| Bulk promotion (project / all)         | `bulk-release/<scope>-<ts>`             |

`<ts>` = `$(date +%Y%m%d-%H%M%S)`. The `bulk-release/` prefix matches what the upstream `bulk-gitops-release` workflow uses internally.

Always `git commit -s` (DCO). Open with the host's CLI; poll until merged when the repo profile says PR-and-wait:

```bash
until gh pr view <number> --json state -q .state | grep -q MERGED; do sleep 30; done
```

Direct push only when the repo profile says so. Don't force-push — fix-forward instead. **Don't open a PR or push without explicit user confirmation.**

## Auth and context

- `occ login` — OIDC interactive; `--client-credentials --client-id <id> --client-secret <secret> --credential <name>` for service accounts.
- `occ config context list` — what every session should verify before touching the cluster.

`component scaffold` and any `get` / `list` need a live context. The other three file-mode generators (`workload create`, `componentrelease generate`, `releasebinding generate`) run **offline** against the repo once `release-config.yaml` or the documented layout is in place — useful for unprivileged developer workstations that can't hit the control plane directly.
