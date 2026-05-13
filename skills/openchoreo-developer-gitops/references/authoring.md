# Authoring

How application CRD shapes get into Git. `occ` ships four file-mode generators that do most of the heavy lifting; everything else hand-authored from `llms.txt` references or templated from cluster.

## Use the scaffolders — don't hand-write

Hard rule. Hand-writing Components / Workloads / ComponentReleases / ReleaseBindings is the source of nearly every onboarding bug — wrong `componentType.kind` default, missing `owner`, indent breakage in env / files, stale release filenames. Always:

| Resource | Command |
| --- | --- |
| `Component` | `occ component scaffold` (sets `kind` from `--clustercomponenttype` / `--componenttype`) |
| `Workload` (BYO) | `occ workload create --mode file-system --descriptor <file>` |
| `ComponentRelease` | `occ componentrelease generate --mode file-system` |
| `ReleaseBinding` | `occ releasebinding generate --mode file-system` |

For source-build Components, **don't** commit the Workload / ComponentRelease / ReleaseBinding by hand — the build pipeline produces them via a PR.

## The four `occ` file-mode generators

**Always pass `--mode file-system` explicitly.** The default for every `occ` generator (`workload create`, `componentrelease generate`, `releasebinding generate`) is `api-server`, which writes to the cluster — wrong for GitOps. `componentrelease generate` *only* supports file-system today and errors if you forget the flag; the other two will silently apply to the cluster. Always set it. Run `occ <command> -h` for the full flag list.

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

Optional file at the GitOps repo root. Overrides the default output directories `componentrelease generate` and `releasebinding generate` use per project / component. Full schema (resolution priority, worked example) in [`../assets/release-config.yaml.example`](../assets/release-config.yaml.example).

Resolution priority: explicit per-component → per-project default → top-level default → (fallback) repo-index resolver matching the documented layout.

When absent, paths are inferred from the repo index per the documented layout. The PE skill (or the user) sets it up during scaffolding — this skill consumes whatever's there. **`--all` and `--project` modes for both generators require this file to be present** (otherwise the generators can't resolve where each binding goes).

## Fetching CRD shapes — `scripts/fetch-page.sh`

For kinds without a file-mode generator (Project, ReleaseBinding overrides, dependency wiring on Workload), use the bundled helper. It resolves the title against `llms.txt`, picks the right version, and prints the rendered Markdown. URL paths are not stable across minors — don't compose URLs by hand.

```bash
./scripts/fetch-page.sh --exact --title "Component"          # full schema, including optional fields
./scripts/fetch-page.sh --exact --title "Workload"
./scripts/fetch-page.sh --exact --title "ReleaseBinding"
./scripts/fetch-page.sh --list                       # dump full llms.txt index
./scripts/fetch-page.sh --exact --title "Workload" --version v1.0.x
```

On a miss (no match / multiple matches / fetch failure), the script dumps the full `llms.txt` to stdout so you can pick by hand.

> `ComponentRelease` and `RenderedRelease` are controller-managed — never hand-author. Use `occ componentrelease generate` for the former; the latter is created by the controller from a `ReleaseBinding`.

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

Every change is a feature branch + PR. Recipes specify branch prefix + commit-message scope; the rest is canonical:

```bash
git checkout -b <prefix>/<scope>-$(date +%Y%m%d-%H%M%S)
git add <files-from-recipe>
git status                                      # show before committing
git commit -s -m "<message-from-recipe>"
git push origin HEAD                            # only after user confirmation
gh pr create --fill                             # only after user confirmation
until gh pr view <number> --json state -q .state | grep -q MERGED; do sleep 30; done
```

| Recipe | Branch prefix |
| --- | --- |
| Onboard a new Component | `release/<component>-<ts>` |
| Update a Component / Workload | `release/<component>-<ts>` |
| Single-env promotion | `release/<component>-promote-<env>-<ts>` |
| Bulk promotion | `bulk-release/<scope>-<ts>` |

`bulk-release/` matches the upstream `bulk-gitops-release` workflow's convention.

### Atomic commits

One logical change per commit. For multi-Component batches, commit per-Component, not per-stage-across-all-Components. Don't `git add -A && commit -m "everything"`.

### Don't force-push, don't amend after push

Fix-forward on a shared branch. **Don't amend after a push** — create a new commit. Amending breaks force-push semantics, loses hook-failure recovery, and rewrites history collaborators may have pulled.

## Auth and context

- `occ login` — OIDC interactive; `--client-credentials --client-id <id> --client-secret <secret> --credential <name>` for service accounts.
- `occ config context list` — what every session should verify before touching the cluster.

`component scaffold` and any `get` / `list` need a live context. The other three file-mode generators (`workload create`, `componentrelease generate`, `releasebinding generate`) run **offline** against the repo once `release-config.yaml` or the documented layout is in place — useful for unprivileged developer workstations that can't hit the control plane directly.
