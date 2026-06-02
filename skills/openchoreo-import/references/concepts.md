# OpenChoreo concepts the importer needs

Just enough of the platform's model to plan a migration.

## Resource model

OpenChoreo's tenancy: a Kubernetes **Namespace** is the tenant boundary; it holds one or more Projects. The importer's plan lands a Project (and everything it owns) inside a chosen Namespace.

The importer **produces** these:

- **Project** — a bounded context grouping related Components and Resources. From the importer's side, it's a grouping decision: which Components belong together because they share a lifecycle, a team, or a domain. How the source maps to Projects is a judgment call. At runtime the platform realizes each Project as a **Cell**.
- **Component** — a deployable application unit (an app, a worker, a job). References exactly one **ComponentType** (immutable) and attaches zero-or-more **Trait instances**. Carries author-facing parameters. Owned by a Project.
- **Workload** — the runtime contract owned by a Component (1:1). Carries the image, env, mounted config files, the endpoints the workload exposes, and the dependencies it consumes (both on other workloads' endpoints and on Resources). This is where the source's runtime info lands.
- **Resource** — a developer's declaration of a managed-infrastructure dependency (database, cache, queue / broker, object store, search engine — anything with persistent-connection semantics the platform should own). References a **ResourceType** and supplies `spec.parameters`; the ResourceType defines named **outputs** (host, port, credentials, url, …) the Workload consumes via `dependencies.resources[]`. Owned by a Project; lives **inside the Project's Cell**, on-platform. **Resource is the canonical abstraction for managed deps — not a judgment call.** The importer's job: identify the dep, name the ResourceType to author, list its outputs. *How* the PE renders the ResourceType is an apply-time implementation choice.
- **SecretReference** — pulls a secret from an external store (Vault, AWS SM, GCP SM, Azure KV) into the cluster as a Kubernetes Secret. Emitted (as TODO skeletons) for any sensitive data the source consumes that isn't already covered by a Resource.

Recommend authoring at the pattern level — a CT / RT / Trait is a template with typed parameters, and many Components instantiate one with their own values. What varies between instances is parameters, not new types. Never write the actual template — the plan recommends, the user authors. List each authored type alongside the Components / Resources that share it.

- **ComponentType / ClusterComponentType** — the template for a *kind* of workload. Fixes the workload shape (`workloadType` ∈ deployment / statefulset / cronjob / job / proxy) and renders the K8s resources from a Workload (Deployment, Service, HTTPRoute, …) via CEL templates; also declares which Traits it accepts and its validation rules. Recommend authoring per pattern — name the CT and say what it renders. A `ClusterComponentType` is cluster-scoped (usable from any namespace); a namespaced `ComponentType` overrides for one namespace.
- **ResourceType / ClusterResourceType** — the ComponentType analogue for managed infrastructure. Carries a parameter schema (e.g. database name, engine version), a per-environment-config schema (e.g. storage size, replicas), templated provisioning resources, and a list of **outputs** (named connection details — host, port, credentials — from literals, Secrets, or ConfigMaps). Recommend authoring per kind of managed infra (one `postgres` RT for every Postgres Resource).
- **Trait / ClusterTrait** — a composable overlay attached to a Component as a named instance. It either **`creates`** new K8s resources (an HPA, an alert rule, a Backend) or **`patches`** resources the ComponentType already rendered (RFC-6902 add/replace/remove — e.g. add a `livenessProbe` to the main container, mount a volume). Recommend authoring per cross-cutting capability (one `observability-alert` Trait attached to many Components).

**Recommending a new one — ComponentType vs Trait.** A ComponentType is the *base kind* of a workload: it owns the primary resource and its mandatory companions, built ground-up from `resources` templates. A Trait is an *add-on capability* layered on top, expressed as `creates` + `patches`. Rule of thumb: if the thing is **always present and defines the workload's shape**, it's a ComponentType; if it's **optional, mix-and-match, or cross-cutting**, it's a Trait. Probes, a sidecar, an HPA, a PVC → Trait-shaped; a brand-new workload shape → ComponentType. Because there's no platform-engineer / developer split in an import, recommending the platform team build one of these is a normal next step, not a blocker.

The importer **doesn't touch but must know exists** (so the hand-off makes sense):

- **Module** — a platform-level capability installed by the PE as a Helm chart, extending one of the **Planes** (DataPlane / ObservabilityPlane / WorkflowPlane / ControlPlane). Categories vary per install — gateways, observability backends (logs / metrics / traces), GitOps reconcilers, networking, workflow engines (for Resource provisioning), and more — the modules catalog at `openchoreo.dev/ecosystem/modules.md` is the live list. **Modules are platform prerequisites, not per-Component dependencies** — installed once per plane, shared across every workload. The importer recognizes module-level signals in the source — a log-shipping DaemonSet → log module; cluster-wide metrics scrapers + ServiceMonitors → metrics module; an ingress controller + Gateway / Ingress CRs → gateway module; ArgoCD / Flux CRs → GitOps module — and surfaces them in the migration plan's **Prerequisites**, not as per-Component deps in the dependency graph or the cell diagram.
- **Environment** — a delivery stage (dev/staging/prod), bound to a **DataPlane** (a target Kubernetes cluster). Created by the platform engineer.
- **DeploymentPipeline** — the directed graph of allowed environment promotions.
- **ComponentRelease / ResourceRelease** — immutable snapshots of (Component + Workload + Traits) and (Resource + parameters) respectively, at a point in time. Lockfiles.
- **ReleaseBinding** — binds a ComponentRelease to an Environment with per-environment overrides.
- **ResourceReleaseBinding** — binds a ResourceRelease to an Environment with per-environment Resource overrides + a per-env retain policy. Apply-time concern; the importer doesn't author these.

## How they connect

```text
Project (grouping → Cell at runtime)
  ├─ Component  ── refers to ──→ ComponentType (template)
  │    │       ── attaches ────→ Trait instance[] (augmentations, each with a name)
  │    │       ── carries ─────→ parameters
  │    └─ Workload (1:1)
  │           ├─ image, env, mounted config
  │           ├─ endpoints                   (what this Component exposes)
  │           └─ dependencies                (endpoints from other Components + Resources)
  │                                              │
  │           ┌──────────────────────────────────┘
  │           ↓
  └─ Resource ── refers to ──→ ResourceType (template, defines outputs)
       │
       │ (snapshot)
       ↓
   ResourceRelease ── bound to ──→ Environment via ResourceReleaseBinding

     ComponentRelease ── bound to ──→ Environment via ReleaseBinding
                                                 │
                                                 └─ rendered K8s resources in the data plane
```

The importer's deliverable is the upper half: Project + Component + Workload + (Resource where appropriate) + Trait attachments + SecretReference. How the rendered resources actually appear in the cluster — Release + Binding ceremony, auto-deploy shortcut, GitOps reconciliation — is the user's apply-time workflow; the importer doesn't choose for them.

## Cross-component wiring

Components talk to each other through declared workload dependencies — not hard-coded Service hostnames. The consumer declares a dependency on a target Component's endpoint and names the env vars it wants the connection details bound into (`address`, `host`, `port`, `basePath`); the platform resolves the endpoint and injects those env vars at deploy time. The importer turns each cross-service reference into a named binding.

A dependency is project-visible by default (same-Project calls) or namespace-visible (cross-Project calls within the same namespace). These endpoint dependencies live under the Workload's `spec.dependencies.endpoints[]`.

**Consuming a Resource** is the sibling mechanism, under `spec.dependencies.resources[]`. Each entry is `{ ref: <Resource name>, envBindings: { <outputName>: <ENV_VAR> } }` — `envBindings` maps a ResourceType **output** name (left, e.g. `host`, `port`, `username`, `password`, `database`, `url`) to an env-var name the developer chooses (right). `fileBindings` mounts an output as a file instead. So for each source dependency that lands as a Resource, the importer recommends a ResourceType to author for it and adds a `dependencies.resources[]` entry that rebinds the source's expected connection env vars to the Resource's outputs.

## Endpoint visibility

Every endpoint is reachable within its own Project + Environment — `project` visibility is the implicit floor (you don't declare it). Endpoints opt into broader scopes via the `visibility` array (it's additive, not exclusive):

- `namespace` — also reachable across all Projects in the **same Kubernetes namespace** (and same Environment).
- `internal` — also reachable across **all namespaces in the deployment** (the cluster's intranet).
- `external` — also reachable from **outside the deployment**, including the public internet.

Dependencies (the consuming side) can only consume `project` or `namespace` visibility — anything broader is hit by its public address, not through `dependencies.endpoints[]`.

The cell diagram derives its directional gateways from these visibility values plus Resource / external edges — see [`frames.md`](frames.md) for the cell-diagram contract.

## What the platform wires up automatically

**Controller-side — always, regardless of CT.** Generated by the reconciler from the Workload + Component:

- **`NetworkPolicy`** — one policy per Component. Every endpoint always opens intra-Cell (`project`) access; the visibility array adds further ingress: `namespace`, `internal`, `external`. Egress is unrestricted. The DataPlane chooses provider via the `openchoreo.dev/networkpolicyprovider` annotation — stock `NetworkPolicy` or `CiliumNetworkPolicy`. Drop the source's NetworkPolicies either way.
- **Connection injection** — the address of a depended-on endpoint or Resource arrives as the env vars you named (see *Cross-component wiring*); no service-discovery code needed.

**CT-template-side — what the CT renders is the CT author's call.** Read `references/sample-types/` for the shipped patterns (`service`/`webapp` render Service + HTTPRoutes; `worker` renders neither). The platform does not enforce a rendering convention — the CT webhook validates schemas, CEL, resource IDs, traits, but never that an `external` endpoint implies a rendered route. Two invariants the samples can't show:

- The `gateway.ingress.{external,internal}.*` contract a CT references is **module-agnostic** — populated from the DataPlane (Environment-level gateway config, when set, fully shadows it). The same template works across any installed gateway Module (kgateway, kong, traefik, envoy, wso2, …) — don't recommend per-module CT variants. Gateway-specific features the source uses (provider-specific annotations, plugins, mesh policies) are only expressible if the install's gateway Module supports them — surface mismatches as caveats.
- Drop the source's hand-rolled Service / Ingress / HTTPRoute / Gateway **only when the recommended CT renders the replacement**. If the recommended CT doesn't, the endpoint isn't reachable through the platform — say so in the plan rather than letting it silently break.

Be precise about what is **not** auto-wired today, so the plan doesn't overclaim: there is no automatic mTLS or service-mesh sidecar, no egress filtering (egress is open), and application-level auth (OAuth2 / OIDC / JWT) is a Trait concern, not core platform behaviour. Recommend authoring a Trait for those, or call them out as gaps — don't list them as platform-handled.

## Resource dependencies

A Workload depending on a Resource is a parallel pattern to endpoint dependencies. The workload declares: which Resource it consumes, plus a mapping of the Resource's named outputs (host, port, credentials, …) onto container env vars and onto file mount paths (for Secret/ConfigMap-backed outputs). The platform resolves the ResourceReleaseBinding for the consumer's environment and injects the actual values at deploy time.

Constraint: a Resource must live in the **same Project** as the consuming Component. Cross-project Resource consumption is not supported.

## Trait instances

A Component doesn't "have Traits" — it attaches **Trait instances**. Each attachment has a stable instance name unique within the Component, plus its own parameters. This is what lets the same Trait (e.g. `hpa`) be attached twice with different policies (`hpa-default` + `hpa-aggressive`), or be tuned per-instance later via a ReleaseBinding override. The importer must give every attachment a deterministic instance name; duplicates are invalid.

## Per-environment overrides (ReleaseBinding)

A ReleaseBinding can override values per environment in three distinct buckets:

- **ComponentType parameters** — knobs declared by the ComponentType template (e.g. resource requests, feature flags).
- **Trait instance parameters** — per-attachment overrides keyed by the trait's instance name (e.g. bump `hpa-default`'s minReplicas in prod).
- **Workload deploy-time overrides** — container env vars and mounted file values applied at deploy. Use these for per-environment secrets and URLs that don't belong in the authored Workload.

When the architect asks "is this per-environment or fixed?", the answer depends on whether the field lives in a CT parameter, a Trait instance parameter, or a Workload env/file — those are the three things ReleaseBinding can shift between environments. Anything else (the ComponentType chosen, the endpoint shapes, the dependency graph) is fixed at authoring time.

## What the Workload model carries

In rough strokes — for exact field names, fetch the live schema.

- One container — image, command, args, env vars, mounted config files
- Endpoints the workload exposes (HTTP, gRPC, GraphQL, WebSocket, TCP, UDP — each with port, target port, visibility, optional base path / schema)
- Dependencies on other workloads' endpoints (referencing a target Component + endpoint name, with explicit env var bindings for connection components like address, host, port, base path)
- Dependencies on Resources in the same Project (referencing the Resource by name, with mappings from ResourceType outputs to container env vars and file mount paths)

The narrowness is deliberate: the platform owns runtime concerns, the workload owns app concerns. The architect's job in this skill is to fit the source into this shape, not to expand the shape.

## What the Workload model does NOT carry

The source will have some of these. The Workload won't carry them — which doesn't mean they're dropped; each maps to a ComponentType-template field or a Trait. Surface every one.

- Probes (liveness / readiness / startup)
- Init containers, multi-container Pods (one container per workload)
- Resource requests / limits for deployment-shaped CTs (cronjob CT exposes this via Component parameters)
- Image-pull secrets / image-pull policy (DataPlane-level, not per-Workload)
- Security context (pod or container)
- ServiceAccount
- Scheduling (affinity, node selector, tolerations, priority class, topology spread)
- Volumes other than ConfigMap/Secret-backed (no `emptyDir`, `hostPath`, `csi`, `projected`, `downwardAPI`)
- Termination grace, DNS policy, host networking, host PID

Each of these is delivered by the **ComponentType template** (baked into the workload's shape) or a **Trait** (an overlay that patches it in) — not by the Workload. When the source needs one, recommend the concrete change: probes → a Trait that patches `livenessProbe` / `readinessProbe` onto the main container; an extra volume → a volume Trait; resource limits → CT parameters. That's a create-this recommendation, not a silent gap. Authoring the template itself is out of scope — the skill names the thing to build.

## ComponentType shapes and validation

The Workload API supports five shapes: `deployment`, `statefulset`, `cronjob`, `job`, `proxy`. The default is to author a CT tailored to the workload's shape.

CTs carry their own validation rules (e.g. some require at least one endpoint, some don't; a cronjob-shaped type tends to keep schedule and limits in Component parameters rather than the Workload). Honor whatever the CT you pick declares, and if the source violates a rule, surface it as a gap.

## Defaults

- **Project grouping is a cohesion call.** A Project groups components sharing a lifecycle / team / domain — not a catch-all. A small, cohesive app is one Project; a large or multi-domain set (past ~15 components, suspect it) should be grouped along the axis the source already implies (subcharts, namespaces, `part-of` labels, directory layout) and confirmed with the user — never crammed into one or split arbitrarily.
- One Component per workload-shaped resource (not per container, not per Service).
- Multi-container Pods → one Component for the main container. For the extras, recommend the path — a Trait that patches them in (per-app, optional), or a custom CT that bakes them into its template (when the extras are always present). Not a silent drop.
- **Managed-infrastructure dependencies** (DB, cache, queue / broker, object store, search engine — anything with persistent-connection semantics the platform should own) → **Resource**. The source might ship its own manifests for it (a StatefulSet for an in-source DB) or only reference an external instance (creds + URL); either way the importer's output is the same — recommend a ResourceType named for the dep with its outputs (host, port, credentials, …); credentials the source pulls become outputs of the ResourceType. The workload binds via `dependencies.resources[]`. *How* the PE renders the ResourceType (in-cluster manifests, cloud-provisioner claim, credentials-only wrapper) is an apply-time choice. Egress is reserved for narrow transactional one-off external calls without persistent-connection semantics.
