---
name: openchoreo-import
description: Plans an OpenChoreo migration from a Helm chart, Kustomize overlay, Docker Compose file, or raw Kubernetes YAML. Triggers on "how can we migrate X into openchoreo", "onboard Y into openchoreo", "bring this app into openchoreo", "model this as openchoreo components", "what would X look like in openchoreo".
metadata:
  version: "1.1.5"
---

# OpenChoreo Import

Take an application spec (Helm chart, Kustomize overlay, Docker Compose file, or raw Kubernetes YAML) and produce a step-by-step migration plan. The plan is the deliverable; the agent iterates with the user as decisions and feedback land.

## Step 0 — Tooling

`node --version` (≥ 18) is always required (the preview server is Node). For each source format, a renderer that turns the input into something analyzable:

- **Helm** → `helm` (≥ 3.12) to `helm template` the chart
- **Kustomize** → `kustomize` (or `kubectl kustomize`) to build the overlay
- **Docker Compose** → nothing extra (the compose file is YAML, read it directly)
- **Raw YAML** → nothing extra

A missing renderer isn't a hard stop — install if possible (rendering is the clean path; values + conditionals + ranges decide what a chart actually emits, so only the rendered output is faithful). If install isn't feasible, do a best-effort enumeration from the raw templates and **flag that the analysis is degraded, not exhaustive** — the plan still ships, just with the limitation called out. Compose and raw YAML need nothing extra.

## Step 1 — Load the model primer (MANDATORY read)

Read [`./references/concepts.md`](./references/concepts.md). The OpenChoreo workload model is intentionally narrow — what fits and what doesn't is the central question of this skill. Load once per session.

## Step 2 — Get the manifests

Identify the source shape and render it to flat K8s YAML — that's what the rest of the analysis works against. If a piece of the input can't be rendered cleanly (a compose feature with no K8s equivalent, an operator-installed chart that needs a live cluster), render what you can and call the rest out as gaps.

| What you find in the input path                                                 | Source shape                                         |
| ------------------------------------------------------------------------------- | ---------------------------------------------------- |
| `Chart.yaml` at root (or nested under `charts/*/`)                              | **Helm chart** (single / umbrella / nested umbrella) |
| `kustomization.yaml` / `kustomization.yml`                                      | **Kustomize** root or overlay                        |
| `docker-compose.yml` / `docker-compose.yaml` / `compose.yaml`                   | **Docker Compose** stack                             |
| `*.yaml` / `*.yml` with none of the above                                       | **Raw K8s YAML**                                     |
| Mix (e.g. Chart.yaml + kustomization.yaml at the same level)                    | Ask the user which to use                            |

**Helm.** Render with `helm template <release> <chart> --namespace <ns> [--values <file>] --output-dir <run>/source-rendered` (run `helm dependency update <chart>` first if `Chart.yaml` has unresolved deps); the render is values-conditional, so render each values file the user actually uses (dev / staging / prod). **Then read the raw templates** under `<chart>/templates/` and `<chart>/charts/*/templates/` to catch the conditional blocks (`{{ if .Values.x }}`, `{{ range }}`) that the current values didn't exercise — those are values-dependent shapes the plan should call out, not silently drop. Also grep for `lookup` (runtime cluster reads — output may be stale on a fresh cluster) and `helm.sh/hook` (no OpenChoreo analogue); flag affected files as gaps.

**Kustomize:** `kustomize build <root> > <run>/source-rendered/all.yaml` (or `kubectl kustomize <root> > …`). Most overlay patterns map to a concrete OpenChoreo construct — a Trait that patches, a per-env override on the binding, a Workload field — figure out which carries the intent and recommend that, instead of flagging. Only call it a gap when the overlay produces a shape the platform can't model at all.

**Docker Compose:** the compose file is already YAML — read it directly and map each `service` to a candidate workload (`image`/`build`, `ports`, `environment`, `volumes`, `depends_on`). Most compose features map to a concrete OpenChoreo construct — a CT field, a Trait that patches, a per-env override, a Workload field — figure out which carries the intent and recommend that, instead of flagging. Only call it a gap when the compose feature has no K8s analogue at all (host-level concerns, node-bound storage).

**Raw YAML:** copy `<input>/` into `<run>/source-rendered/`. The file IS the manifest.

**Each file may contain multiple YAML documents separated by `---`** — split by docs, not files. From here on, the analysis works on the rendered docs.

## Step 3 — Inventory, then assess fit

**Inventory first — read-only, classify *every* rendered doc by kind:** workloads (Deployment / StatefulSet / CronJob / Job), discovery (Service / Ingress / HTTPRoute), config (ConfigMap / Secret), augmentations (HPA / PDB / ServiceMonitor / …), RBAC (ServiceAccount / Role / …), cluster-scoped & infra (CRD / webhook / operator / DaemonSet), foreign CRs. Every document lands in a bucket — an unclassified doc is a hole, and under-reading a big chart is the most common cause of a wrong plan. This one pass feeds both the fit verdict here and (for good-fit / partial-fit) the dependency ledger you'll build per [`./references/build-the-plan.md`](./references/build-the-plan.md).

Then **assess fit** — three buckets:

- **good-fit** — every resource in the source maps to an OpenChoreo primitive (Component, Workload, Resource, Trait, SecretReference). Predominantly workload-shaped (Deployments / StatefulSets / CronJobs / Jobs), no CRDs, no admission webhooks, no node-level DaemonSets, no cluster-scoped RBAC. **Bundled stateful services that extract to a Resource still count as good-fit** — extracting to a Resource is just a different primitive, not a loss. Proceed.
- **partial-fit** — workloads map cleanly, but some resource in the source **genuinely cannot be brought into OpenChoreo** and requires action outside the import: cluster-scoped RBAC, foreign CRs that depend on an external controller, an admission webhook the workloads need. Proceed and surface the out-of-scope pieces. (Needing a new ComponentType / ResourceType / Trait is *not* a partial-fit trigger — authoring is routine and surfaced as a create-this recommendation in the plan.)
- **not-a-fit** — dominantly infrastructure: operator install (CRDs + controller), CNI / network plugin, admission controller, APIService aggregator, DaemonSet-only. **Stop. Don't pretend to model.** Show the verdict + the signals; what the user does next with the source is out of scope.

Classification signals: `CustomResourceDefinition` → operator install (`not-a-fit`); `MutatingWebhookConfiguration` / `ValidatingWebhookConfiguration` → admission (`not-a-fit`); `APIService` → aggregator (`not-a-fit`); only `DaemonSet`s → node agent / CNI (`not-a-fit`); `ClusterRole` / `ClusterRoleBinding` → `partial-fit` or `not-a-fit`; pure workloads → `good-fit`.

**Before emitting the verdict, answer in chat:** total rendered docs read, total classified, any unclassified (name them). An unclassified doc means the inventory isn't done — not a verdict you can ship.

Deliver the verdict + findings **in chat** — a short headline (good-fit / partial-fit / not-a-fit) and the signals behind it. No browser, no server for this step. For `not-a-fit`, that's the whole journey — stop there.

**For `good-fit` / `partial-fit`, read [`./references/build-the-plan.md`](./references/build-the-plan.md) before continuing** — it carries the post-verdict playbook. Don't barrel from verdict straight into a finished plan on your own guesses.

## What this skill does NOT do

- Touch the cluster. No `kubectl`, no MCP, no apply.
- Rebuild from source. BYOI by default — the image is whatever the user supplies at apply time; the skill doesn't evaluate registry access, image-pull credentials, or source licensing.
- Write the actual ComponentType / ResourceType / Trait YAML. The plan **recommends** what to author; the template is the user's to write.
- Pick deployment mode (auto-deploy vs GitOps vs manual apply), rollout strategy, or per-environment values — apply-time concerns the user owns.

## Hard nos

These apply every turn, every step — not "during planning." Treat them as session-wide rules.

- **Don't sample.** Read every workload, config, parameterization file, and grouping. Render before classifying — static parsing misses values-conditional shapes.
- **Delegate sweeps to sub-agents at scale.** >5 groupings, >10 files this turn, or verdicting a large source → fan out one sub-agent per shard, each returns a summary, collapse back. Concurrent main-context Bash/Read still consumes *your* context — not sharding. (Claude Code: `Agent` tool; `ToolSearch select:Agent` if not loaded.)
- **Never `cd`.** Absolute paths in every Bash. `cd` mutates `$PWD`; the next `preview.sh new "$PWD"` then scaffolds `.openchoreo-import/` wherever you last `cd`-ed (including inside the skill install).
- **Don't author per-Component.** A CT / RT / Trait captures a pattern; many Components instantiate one. Visibility, replicas, sizes, env values are *parameters*, not different types.
- **Don't ask type internals.** What a CT / RT / Trait renders is PE-side authoring. The plan recommends the pattern.
- **Don't ask intent.** Lift-and-shift vs re-model, applying vs exploring — none of it changes the plan. Forks ask about source ambiguity, never user goals.
- **Don't thin the diagram.** Every dependency renders. Split into more Projects to drill down, never drop edges for readability.
- **Don't take silence as acceptance.** If a fork wasn't answered, re-ask.
- **Don't build the page before forks are answered.** Forks are chat-only.
- **Always recommend authoring CT / RT / Trait — never reference shipped.** The skill can't know what ships (no install introspection). Bundled samples in `references/sample-types/` are *shape reference*, not a menu. A foreign CR (apiVersion outside standard K8s + `openchoreo.dev/*` + `gateway.networking.k8s.io/*`) implies an external controller.
- **Don't flag runtime concerns as blockers.** Image-pull / registry access / licensing → apply-time. Calls into in-flight legacy peers → `external` with *swap-when-onboarded*; not a fit failure.
- **Loud about gaps; conclusions, not disclaimers.** Quietly unmapped resources mislead. Don't preface the plan with hedges — genuine forks go in the verdict-beat ask.
- **Run the end-of-turn checklist before closing.** See [`build-the-plan.md`](./references/build-the-plan.md) → *End-of-turn checklist*; a failed item = re-do. On the approval turn (the one that writes `migration-plan.html`), run it **out loud** — each item with pass / fail in chat, before the three-file write.
