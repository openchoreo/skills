# Build the plan

The post-verdict playbook: map → ask the forks → drive the page → iterate → hand off.

## Sources for shape recommendations

Before naming any CT / RT / Trait in the plan — shipped or authored — read the relevant bundled sample. Recommending shapes from memory drifts silently from real CT/RT/Trait shapes. **These are capability reference; authoring the YAML isn't part of this skill.**

- `references/sample-types/component-types/service.yaml` — sample CT (renders Service + HTTPRoutes).
- `references/sample-types/component-types/webapp.yaml` — sample CT (renders Service + HTTPRoutes).
- `references/sample-types/component-types/worker.yaml` — sample CT (no endpoints; renders no Service / HTTPRoute).
- `references/sample-types/resource-types/postgres.yaml` — sample RT.
- `references/sample-types/traits/persistent-volume.yaml` — sample Trait.

Online catalog (only when the bundled samples don't cover the shape, or to confirm a name actually ships):

- `https://openchoreo.dev/ecosystem/component-types.md` — shipped ComponentTypes index.
- `https://openchoreo.dev/ecosystem/modules.md` — pluggable Modules the PE installs (gateways, observability backends, etc.). Only fetch when the source uses a vendor-specific feature you'd need to flag as a prerequisite.
- `https://openchoreo.dev/llms.txt` — only fetch if you need the index to find a specific doc page.

## Working style on this path

- **The page is the channel.** Don't dump the plan into chat. Update the run's `content/index.html` (absolute path); the user reads the page. Chat is for short hand-offs and feedback.

## Map the source

**Two passes, doubt-driven.** Pass 1: classify every doc + build the ledger. Pass 2: reconcile the ledger + adversarially re-read it before the verdict. The first pass alone is never enough — the second is what catches what the first missed.

**At scale, shard with sub-agents.** If your host exposes one, parallelize pass 1 (one agent per grouping or per kind, summaries collapse back) and run pass 2 with a fresh-context agent diffing source against the in-progress ledger.

For each rendered document:

- **App-code workload** — a Deployment / StatefulSet / CronJob / Job running the app's own code (not a backing service like a DB / cache / queue / store; those go to the next bullet as Resources) → one Component + Workload. Recommend a ComponentType per pattern — cluster Components by shared shape so one CT covers a group. Name each and say what it renders.
- **Managed-infrastructure dependency** — anything with persistent-connection semantics the platform should own (database, cache, queue / broker, object store, search engine). The source might **ship its own manifests** for it (a StatefulSet for an in-source DB) or **only reference an instance** (creds + URL, no workload manifests); either way → **Resource**. **Recommend one ResourceType per kind of managed infra**, reused across every Resource of that kind (one `postgres` RT for every Postgres Resource) — name it, list its outputs (host, port, credentials, URL, …); credentials the source pulls become outputs of the ResourceType, not separate SecretReferences. The workload binds via `dependencies.resources[]`. (*How* the PE renders the ResourceType is an apply-time choice.)
- **External call** — anything the workload reaches over the network that isn't in this import: a transactional one-off (webhook handler, fire-and-forget POST), a permanent legacy peer, or a sibling app coming in a later phase. Render as a `container.env` entry with the URL as `value:` plus a **SecretReference** for credentials — no Resource ceremony, the structure isn't worth it. If the dependency is a candidate to onboard later, tag it *candidate peer — swap to `dependencies.endpoints[].project: "<peer>"` when onboarded*: the swap drops the literal env var, adds a `dependencies.endpoints[]` entry with `envBindings: {address|host|port → ENV_VAR}`, and the platform resolves the in-cluster address itself.
- **Discovery** (Service, Ingress, HTTPRoute, GRPCRoute, TCPRoute) → folds into the owning workload's endpoints; the ComponentType template renders the right Service + route per endpoint, wired to the gateway by visibility. If the discovery is non-standard (multiple gateways, custom route patterns, TCP / UDP exposure, side resources), recommend a **custom ComponentType** that renders the bespoke shape, or a **Trait** that patches / creates the extra discovery resources — don't silently drop the shape.
- **Config** (ConfigMap, Secret) → folds into the workload's env vars and mounted config files. Sensitive data → **SecretReference**, including external-secret-store integrations (`SecretProviderClass`, `ExternalSecret`, etc., regardless of which store backs them) — each becomes a SecretReference; never model the external store as a Resource and never embed literal secret values. *Caveat:* if the ConfigMap/Secret is an output of a Resource you're emitting, the wiring is a workload-on-Resource dependency (see [`concepts.md`](concepts.md) → *Cross-component wiring* / *Resource dependencies*) — drop the duplicate.
- **Augmentation** (HPA, PDB, ServiceMonitor, …) → Trait attached to the owning Component. **Recommend one Trait per cross-cutting capability**, reused across every Component that needs it (one `hpa` Trait for every horizontally-scaled Component) — name it and what it should patch / create. Each attachment gets a stable instance name; distinct names when attaching the same Trait twice with different parameter values. *Note:* `NetworkPolicy` is platform-handled — OpenChoreo generates per-Component policies from endpoint visibility (see concepts.md), so drop the source's own.
- **Foreign CR** (apiVersion outside standard K8s + `openchoreo.dev/*` + `gateway.networking.k8s.io/*`) → external dependency on the implied controller.
- **Platform-capability signals** — cluster-wide infrastructure the source ships (log-shipping DaemonSets, cluster-wide metrics scrapers, ingress controllers + Gateway / Ingress CRs, GitOps reconciler CRs) maps to a **Module the PE installs**, not per-Component deps. Surface as **Prerequisites** in the migration plan; don't put on the cell diagram or per-Component dependency list. (See [`concepts.md`](concepts.md) → *Module*.)
- **Cluster-scoped K8s primitives** (CRD, ClusterRole, webhook, APIService) without a module-capability fit → not a developer workload. Gap or external.
- **Hooked / `lookup`'d** (Helm only) → gap.
- **Kustomize-only artifacts** (orphan patches, components not in any overlay) → invisible after `kustomize build`; if surfaced, treat as raw YAML.

**Phased migration is the default — legacy callbacks aren't a blocker.** A workload calling into legacy / external infrastructure (the old control plane, an old shared service, a co-tenant cluster) is *not* disqualified. Pieces come over part by part; a migrated piece keeps calling the legacy peers it hasn't waved goodbye to yet. Model the legacy peer as `external` with a *candidate peer — swap to `dependencies.endpoints[].project: "<peer>"` when onboarded* note.

**Soft heads-up — Module overlap.** If the source ships platform-shaped infrastructure (its own gateway / ingress controller, observability stack, log shippers, identity / SSO, service mesh, GitOps reconciler) and OpenChoreo's Module catalog has an equivalent, mention it *once* as a soft alternative: "OpenChoreo provides X Module; consider using it instead." Never a gate — the user might prefer the platform's Module or keep the source's stack running externally; either's valid.

**Build the ledger — one row per workload, before you write any plan.** A structured table is what keeps a big chart from leaking units and edges:

| workload | → ComponentType | endpoints (port / visibility) | depends on (→ Resource / egress / calls) | config & secrets | augmentations → Trait |

The cell model and the *Types & Traits* / *Projects & Components* tabs are **derived from this ledger** — every workload is a row (none skipped) and every dependency is a cell (none dropped). An empty *depends on* cell is a prompt to look harder, not a default.

**Capturing dependencies — sweep exhaustively, don't sample.** Dependencies are the most-missed part of an import; a source rarely declares them in one place, so go looking. **Read every workload, every ConfigMap, every Secret, every parameterization file, every grouping** — *parameterization file* = `values.yaml` (Helm) / `kustomization.yaml` patches + `configMapGenerator` / Compose `environment` blocks + `env_file` / overlay env files (raw YAML); *grouping* = subchart (Helm umbrella) / base or overlay (Kustomize) / service (Compose) / directory (raw YAML). Reading "a few" is not the job; reading them all is. Scan every source for connection signals:

- **Env vars / config that name an address or carry store credentials**: `*_URL` / `*_URI` / `*_HOST` / `*_ADDR(ESS)` / `*_ENDPOINT` / `*_PORT` / `*_DSN`, a `*_PASSWORD` / `*_USER` / `*_KEY` paired with a host, `<NAME>_SERVICE_HOST` (k8s-injected), and raw connection strings — in the container, ConfigMaps, and Secrets. Cover **every** backing-store category — relational, document, key-value, cache, queue / broker, search, vector, object store.
- **`args` / `command`** flags carrying addresses (`--upstream=`, `--backend=`, `-addr=`).
- **initContainers / wait-for gates** (`until nc -z <host>`, `wait-for-<svc>`) — a hard startup dependency.
- **Service / Ingress / HTTPRoute backends** and **`values.yaml`** keys pointing at other services/releases.

Classify each and record it on the consuming Workload (and the cell model):
- depends on something **in this import** (in-cluster Service DNS) → a `dependencies.endpoints[]` entry naming the target Component + endpoint + `envBindings: {address|host|port|basePath → ENV_VAR}` (the env var names are the consumer's choice). Cross-project: add `project: "<other>"`. Drop the literal address env from the source — the platform re-injects it via the binding.
- depends on a **managed-infrastructure thing** (database, cache, queue / broker, object store, search engine) → **Resource** → `resources` + `dependencies.resources[]`. Default doctrine — not asked. External calls (transactional one-off, legacy peer, future peer) → `external` (workload env var + SecretReference).

**Then reconcile — a completeness gate, before the verdict.** Go down the ledger row by row: every address-like env / connection string you found must resolve to an edge — a `calls` (target in this import), a `resources` (managed store), or an `external` (egress). If something names a host and has no edge, that's a miss — add it. **A component with zero edges is a red flag** when other components in this import clearly call each other — re-check before accepting it as standalone. **Before any zero-edge Component lands in the plan, answer in writing:** what concrete evidence (a config flag, a deliberately-isolated subchart, an explicit "no upstream" note in source) says this is standalone, not under-swept? "Couldn't find any signals" is *not* evidence of standalone — it's evidence of a shallow sweep. Under-wiring the graph is the most common failure on big sets — orphans usually mean a shallow sweep. Conversely, **don't invent edges**: every dependency must trace to runtime wiring the container actually consumes. The test before adding an edge: *can I name the path from this string to the running container?* When wiring is **bulk** (`envFrom`, broad config mounts), YAML reveals injection, not consumption — over-attribute keys to every consumer, but tag the dep with its bulk source so they show as bundled-not-confirmed.

**Multi-container Pods** — a Workload runs a single container. Surface every other container (init / sidecar) and recommend the path: a Trait that patches the extra container in (per-app, optional), a custom ComponentType that bakes the extras into its template (when always present), or the containers split into separate Components. Not a silent drop.

**Project boundary.** A Project is a cohesion boundary (shared lifecycle / team / domain), not a catch-all. A small, cohesive app is one Project — propose it. A large or multi-domain set isn't — read the grouping the source already implies (subcharts, namespaces, `part-of` labels, directory layout, ownership) and present a split + the axis as a fork for the user. Resources live in the same Project as their consumers, so the split also decides where shared infra lands.

**Doubt the analysis before the verdict.** A confident reading isn't a complete one — on a big chart you've almost certainly under-swept somewhere. Re-read your own ledger adversarially, trying to *disprove* it rather than confirm it: which `depends on` cell is suspiciously empty? which datastore category never appeared though the app clearly needs one? which dependency did you infer with no concrete signal (a flag, a name)? do the cell model, *Types & Traits*, and *Projects & Components* tabs agree? is the project grouping defensible or a hunch? Run the *Red flags & rationalizations* checklist as questions you must answer, not a list you skim. For any large source, beat self-review — it shares your blind spot. Dispatch a **fresh-context reviewer** to diff source against plan page; ask for: workloads the plan doesn't account for; cell-model edges the plan asserts but the source doesn't support; cross-component calls the plan missed.

## Ask about the genuine forks (what the source can't decide)

Most of the mapping is settled by the source plus the catalog — apply it and move on; don't narrate every default. But some points are **genuine forks**: the same source admits more than one legitimate mapping, and which is right turns on what the user wants the platform to *do*, not on anything in the manifests. **Surface every fork, with your recommendation, and ask** — batched, in chat. You can't read intent off the source, and silently guessing is how the plan comes out wrong.

**The test for a fork** (judgment, not a checklist): could a competent reviewer read the same source and reasonably map it a different way, with the difference mattering? If yes, ask. If the source, the catalog, or the docs settle it, don't — default it. **Recognizability is a trap:** knowing *what* something is (a database, a hosted model, a queue) tells you nothing about how the user wants it *modeled*.

**Don't ask about:**

- **Anything apply-time.** This skill plans, period. Auto-deploy vs GitOps mode, which environment to deploy to first, rollout strategy, kubectl / occ workflow — all out of scope. The user takes the plan and applies it however they want.
- **User intent / strategy / authorization.** "Lift-and-shift vs re-model natively," "are you committed to applying," "exploring vs proceeding" — all fake forks. The skill always produces a plan; the *pattern-level CT / RT / Trait recommendations in that plan ARE native re-modeling*, not a separate mode. There is nothing to authorize.
- **Per-environment overrides.** Listing what the platform CAN override per env is fine; asking the user to define values is not.
- **The obvious single-Project case** — a *small, cohesive* app → one Project; propose it, don't ask. (A large or multi-domain set is the opposite — its grouping is a genuine fork to ask about.)
- **Mappings already documented in the catalog or concepts.md.** Apply the default and surface it as a decision; let the user push back via feedback.
- **External-secret-store integrations** → **SecretReference** (see [`concepts.md`](concepts.md)).
- **Managed-infrastructure deps** → **Resource** — every time. **Component-vs-Resource is not a fork; never ask.** Resource is the canonical abstraction for any persistent-connection managed dep (see [`concepts.md`](concepts.md)).
- **Pipeline / Environment / DataPlane choice** — migration-time, not plan-time. The migrator picks when applying; don't surface as a fork.
- **Type template internals** — PE-side authoring decisions baked into the CT / RT / Trait. The plan recommends the pattern; what's inside is the pattern's definition.

**Forks that recur** (illustrations — recognize the shape, then find the rest yourself; this is not the whole set):

- **Project boundaries** — whenever the set is large or spans domains (past ~15 components, assume it does). Don't cram them into one Project *or* split arbitrarily: derive a grouping from the source's own structure (subcharts, namespaces, `part-of` labels, directory layout) and ask the user to confirm the split + the axis. Only a small, cohesive app skips this.
- **Exposure / visibility** — when the source's networking doesn't map cleanly onto OpenChoreo's visibility model.
- **Component shape** — when something fits two ComponentTypes with material tradeoffs.

**At the verdict beat.** Surface the forks via the `AskUserQuestion` tool (or its host equivalent) — **in batches of up to 4 per turn** (the tool caps at 4 questions). If more forks remain, split across turns; lead with the most structural ones (Projects, Component shape) — the ones that change the most downstream. Each fork carries your recommendation so the user can rubber-stamp or flip in one click. Build the plan on their answers.

Per-dependency mapping is mostly settled by the defaults (managed-infrastructure → Resource, external-secret-store → SecretReference) — those land in the plan, not the ask. What reaches the ask is **structural**: Projects, visibility, Component shape, deployment topology.

The **shape** of that ask (a format to follow — fill it from the actual source; never copy these placeholders):

```text
Before I build the plan — a few decisions the source can't settle (reply "go"
to take all recommendations, or flip any):

1. Projects — one, or split into <groups> along <axis>?    [your recommendation]
2. <Component name> shape — <CT-A> vs <CT-B>?              [your recommendation]
3. <Component name> exposure — <visibility-A> vs <visibility-B>? [your recommendation]
```

## Drive the page through `content/index.html`

The skill ships **state-specific frames** under `assets/frames/`. Each turn, write a fragment of HTML into `current/content/index.html` with a directive on the first line that picks the frame:

```html
<!-- oc-frame: plan -->
… your content for this state …
```

The server splices your body into the matching frame and reloads the browser (via WebSocket). Two frames: `plan` (`content/index.html`, the iteration target) and `report` (`content/migration-plan.html`, the migration plan). The verdict + findings stay in chat — not a frame.

For the per-frame content contract see [`frames.md`](frames.md); for the migration-plan content see [`migration-plan.md`](migration-plan.md); for the server / lifecycle / event details see [`plan-preview.md`](plan-preview.md).

**Flow:**
- **good-fit / partial-fit:** sweep the source **exhaustively** first → verdict + findings **in chat** → ask forks in chat → iterate the plan in `index.html` → on approval, write `migration-plan.html`, `plan.md`, and the *View migration plan →* nav button on `index.html` — together.
- **not-a-fit:** verdict + findings **in chat** — terminal, nothing to proceed to (no server, no browser)

**Server lifecycle** — nothing needs the server until there's a plan to show, so it spins up on the turn you first build the `plan` (not for the verdict, which is chat-only).

Run `preview.sh` by its **absolute path** (`<skill-dir>/scripts/preview.sh`, where `<skill-dir>` is this skill's base directory, printed when the skill loads). Read/write the run's files by absolute path too. The script creates `.openchoreo-import/` under the directory you pass it — keep that the directory you're already in (`"$PWD"`); cd-ing drops temp state in the wrong place.

**Order matters: `new` → write → `start` → `open`.** The script enforces it — `start` refuses to launch without `current/content/index.html`, so calling them out of order errors with a clear path rather than dropping the user on the server's "not ready" placeholder.

1. `<skill-dir>/scripts/preview.sh new "$PWD" <slug>` — creates the run under `$PWD/.openchoreo-import/` + points `current` at it. **No server yet.** (`<slug>` = a short name, e.g. the chart name.)
2. Write the `plan` frame to `$PWD/.openchoreo-import/current/content/index.html` (absolute path — don't cd to it).
3. `<skill-dir>/scripts/preview.sh start "$PWD"` — spawns the server, prints the URL. **Does not open the browser.**
4. `<skill-dir>/scripts/preview.sh open "$PWD"` — opens the browser; it lands on the rendered plan.

Subsequent turns: just rewrite `$PWD/.openchoreo-import/current/content/index.html` (still no cd). Server detects the change, browser refreshes via WebSocket. Don't re-run `open` unless the user explicitly closed the tab.

## Iterate

Each turn, read `current/state/events.jsonl` — every line is a fresh user interaction since the last regeneration (the server truncates the file on every write to `current/content/`). Fold those plus the chat message into a new `current/content/index.html`, write it, end the turn. The browser refreshes via WebSocket.

Don't restart the server. Don't re-render the rendered manifests under `source-rendered/` unless the input source itself changed.

## Hand off back to the user at the end of every turn

The agent has no live subscription — browser clicks land in `events.jsonl` immediately, but the agent only reads it when the user sends a chat message that wakes the next turn. Without a prompt to return to chat, the user clicks around, nothing happens, and they wonder why.

**Every turn that ends with a page expecting interaction must close the chat with a short hand-off**: one sentence on what's on screen, one sentence on how to come back (send any message — `next`, `done`, anything). When you've delivered the migration plan, say so and point at it (the *View migration plan →* button in the top app-bar; *← Back to plan* returns). (A `not-a-fit` verdict is chat-only and self-evidently terminal — no page, no hand-off needed.)

Don't prescribe a script — write the hand-off in your own words each turn, fitted to what just changed.

## Red flags & rationalizations

You've under-analyzed the source if:
- **Most components have no edges** — when other components in this import clearly call each other, an orphan-heavy graph means you under-swept.
- **A dependency shows up in one surface but not another** — egress in the diagram but a Resource in a tab, or a ResourceType listed that no `resources` edge references.
- **A whole backing-store category is missing** though its env vars are present.
- **A dependency can't be traced to a concrete signal** — you inferred it from a feature flag or a suggestive name.
- **A rendered doc never landed in the Step-4 inventory.**

| Rationalization | Reality |
|---|---|
| "It's obviously egress" | What a dependency *is* ≠ how the user wants it owned. Enumerate it and ask. |
| "The chart's small, I'll eyeball it" | Eyeballing is how a whole datastore and half the call graph get dropped. Build the ledger. |
| "One Project keeps it simple" | A flat bag of 30 services is several domains, not one Project. Group it. |
| "No edges, so it's standalone" | When other components in this import clearly call each other, edge-less almost always means missed dependencies. |
| "I'll sample and flag it for the user to verify" | Sampling-with-caveats is failure dressed as humility. Sweep, then hand off conclusions. |
| "A cheap check would confirm — I'll note it" | Then do the cheap check before handing off. Hedges aren't honesty. |
| "Dropping edges to keep the diagram readable" | Density is information; the diagram exists to show it. Split into more Projects to drill down — never thin edges. |

## Build-path guardrails

- Don't stuff fields the Workload model doesn't carry (probes, init containers, resource limits, security context) into the Workload. These are delivered by the ComponentType template or a Trait — recommend the concrete one (e.g. probes → a Trait that patches the main container).
- When proposing a new ComponentType / ResourceType / Trait, you name it and describe what it renders — don't ask the architect to type the name, and don't imply it already exists in the catalog.
- **Resources live in the same Project as their consumers.** Cross-project Resource consumption is not supported — surface as a decision if the grouping forces it.
- **Trait attachments need stable instance names.** Two attachments of the same Trait with the same instance name is invalid.

## End-of-turn checklist

Run through this before closing any turn that does planning work. Silently is fine on iteration turns — but **on the approval turn (the turn that writes `migration-plan.html`), run it out loud: list each item with pass / fail in chat before writing the three files.** A failed item means re-do, not ship.

- **Sweep coverage.** Did I read every workload? every parameterization file (values.yaml / kustomize patches / compose env / overlay files)? every grouping (subchart / base / overlay / service / directory)? Cite counts. "Most of them" isn't a count.
- **Zero-edge Components.** For every Component with no outgoing edges, did I name concrete evidence it's standalone? "Couldn't find any" isn't evidence — re-sweep.
- **Sample-checked recommendations.** For every CT / RT / Trait I named in the plan, did I read the matching `references/sample-types/*.yaml` first?
- **Fork hygiene.** Did I ask any intent / strategy / authorization fork? If yes — strip from the batch, re-ask with only source-ambiguity forks.
- **Order discipline.** Did I write to `content/index.html` before every fork was answered? If yes — revert, re-ask, write after.
- **Reviewer dispatch** *(when applicable — large sources, or >~20% zero-edge Components).* Did a fresh-context reviewer diff source against plan? If skipped, why?

The checklist runs *last* on purpose — it's the final pass that survives drift from everything earlier in the turn.
