# The migration plan (`report` frame)

The import's final deliverable. **Not a summary of what happened** — a forward-looking, **project-by-project (cell-by-cell)** plan someone follows to bring the app onto OpenChoreo and apply it to a cluster, with enough detail per section that a competent reader can author the YAML without re-reading the source.

OpenChoreo's runtime unit is the **Cell** (Project × Environment × namespace). The plan's rhythm is **migrate one Project, validate it works, then migrate the next** — the *Definition of done* at the end of each per-Project section is the gate. The plan tracks intent; the cluster (ReleaseBindings + ResourceReleaseBindings + their Ready conditions) is the source of truth for what actually shipped.

## Persistence + navigation

The `plan` preview and the migration plan are **separate content files** so neither clobbers the other:

- `content/index.html` — the `plan` preview (`<!-- oc-frame: plan -->`), the iteration target.
- `content/migration-plan.html` — this document (`<!-- oc-frame: report -->`).

The `report` frame ships **← Back to plan** and **Copy migration-plan.md** buttons in the top app-bar. **The migration plan write is atomic — four files in lockstep:**

1. `content/migration-plan.html` — the rendered report page (this file).
2. `content/migration-plan.md` — the Markdown twin of the migration plan. The `Copy migration-plan.md` button fetches `/migration-plan.md` — if it's missing, the UI hides the button.
3. `content/plan.md` — the architecture plan Markdown. The optional `<details class="plan-preview">` disclosure on the plan page fetches `/plan.md` — if it's missing, the UI hides the control.
4. `content/index.html` — add the **View migration plan →** button to the plan page's `nav` slot: `<div data-fill="nav"><a class="btn ghost" href="/migration-plan.html">View migration plan →</a></div>`.

## Sections (in order)

### 1. Questions for the migrator

Decisions only the migrator owns — the source can't tell you these. Each carries the agent's **recommendation** (derived from source signals); the migrator rubber-stamps or flips. Settle these before working through 2 onward, because each shapes what gets authored downstream.

#### 1. Secret store backend
ESO → `ClusterSecretStore` → backend. Default in shipped installs is **OpenBao** (in-cluster Vault fork; what k3d + quickstart use). Substitute if the install already uses Vault / AWS Secrets Manager / GCP Secret Manager / Azure Key Vault / other.

*Recommendation* — derive from source: if the manifests reference a specific backend via `ExternalSecret` / `SecretProviderClass`, recommend that store; otherwise OpenBao.
*Confirm* — is a `ClusterSecretStore` already installed? If yes, name it; the per-Project SecretReferences below assume it.

#### 2. Secret seeding mechanism
How secret material reaches the backend. Options:
- `occ secret create` — when `features.secretManagement.enabled` is on (default for k3d + quickstart) and `occ` ≥ v1.1. Control plane writes through to the target plane's store.
- Backstage Secrets UI — same path, browser-driven.
- Direct provider CLI — `bao kv put`, `vault kv put`, `aws secretsmanager put-secret-value`, etc.
- Pre-seeded by another process — the plan only authors `SecretReference`s.

*Recommendation* — per env if they differ (e.g. dev uses `occ`, prod is pre-seeded by an external pipeline).

#### 3. ResourceType implementation strategy (per Resource)
How each `ResourceType`'s `resources[]` provisions the infra:
- **In-cluster K8s primitives** — StatefulSet / Deployment + Service / ConfigMap / ExternalSecret (the pattern `references/sample-types/resource-types/postgres.yaml` shows).
- **Crossplane Compositions** — declarative cloud infra via Crossplane.
- **Cloud operators** — AWS Controllers for K8s / Azure Service Operator / GCP Config Connector.
- **Terraform / Pulumi via a Workflow CR** — imperative provisioning kicked off by the platform.
- **Already-managed externally** — the RT does no provisioning; its `outputs[]` source from a pre-existing `SecretReference` / `ConfigMap` the PE created. The RT is a typed accessor over existing credentials.

*Recommendation* — per Resource; commonly mixed (dev = in-cluster, prod = Crossplane / cloud-operator / already-managed).

#### 4. Build strategy (only if any Component builds from source)
Per Component:
- **Workflow template** — pick from the install's `allowedWorkflows[]` for the chosen CT. Default catalog ships `dockerfile-builder`, `paketo-buildpacks-builder`, `gcp-buildpacks-builder`, `ballerina-buildpack-builder`; PEs can author custom `ClusterWorkflow`s. Or **BYOI** (skip the build, supply a pre-built `spec.container.image`).
- **Git provider** — GitHub / GitLab / Bitbucket / Gitea / other. Drives the credential shape.
- **Git credentials** — `SecretReference` in the project namespace targeted at the `ClusterWorkflowPlane`, category `git-credentials` (`occ secret create generic <name> --target-plane ClusterWorkflowPlane/<wp> --category git-credentials --from-literal=username=… --from-literal=password=…`).

*Recommendation* — per Component (typically the same template across all from-source Components in an app).

### 2. Cluster prerequisites

What must exist at the cluster level before any project migrates. A standard OpenChoreo install provides most of it — **flag only what's missing or needs adapting** for this app; mark the rest "assumed present (standard install)".

**Always required:**

- **Control-plane Namespace** labelled `openchoreo.dev/control-plane: true` (the `default` namespace is auto-labelled at install).
- **DataPlane** (or `ClusterDataPlane`) — the target Kubernetes cluster, referenced by Environments. A standard install provides a cluster-scoped `ClusterDataPlane: default` visible to all namespaces; flag a dedicated `DataPlane` only if this app needs isolation.
- **Environment(s)** — `spec.dataPlaneRef {kind, name}`, `spec.isProduction`. A standard install provides `development` + `staging` + `production`; flag any extra (or renamed) env the app needs.
- **DeploymentPipeline** — `spec.promotionPaths[]` of `{sourceEnvironmentRef, targetEnvironmentRefs[]}`. A standard install provides `default` (development → staging → production); flag a custom pipeline only if the app's promotion differs. Every Project pins to exactly one pipeline.

**Conditional (only if this app needs them):**

- **External Secrets Operator (ESO) + `ClusterSecretStore`** — required as soon as any Workload consumes a secret (almost always). OpenChoreo's secret path runs through ESO: secret material lives in an external store (OpenBao by default, or whatever 1.1 picked), and a `ClusterSecretStore` connects ESO to it. The DataPlane references the store via `spec.secretStoreRef: {name: <store>}`. If the install lacks ESO + a `ClusterSecretStore`, this is a hard prerequisite — install ESO (`helm upgrade --install external-secrets …`), create a `ClusterSecretStore`, wire `spec.secretStoreRef` on the DataPlane.
- **WorkflowPlane + ClusterWorkflowTemplates** — required if any Component builds from source. Default install ships the four default builders (see 1.4); flag only custom workflow templates the app needs.
- **ObservabilityPlane + NotificationChannel** — required only if the app uses an observability-alerting Trait. Each alert Trait needs at least one notification channel — either the Environment's default or a per-Trait one. Flag the channels by name + type (Slack / email / webhook / …).
- **Secret Management API gating** (`features.secretManagement.enabled` on the `openchoreo-control-plane` chart) — required to use the `occ secret create` / Backstage path from 1.2. Enabled by default in the k3d single-cluster install and quickstart; for any other deployment, `helm upgrade … --set features.secretManagement.enabled=true`. Without it, only the direct-provider-CLI / pre-seeded paths from 1.2 work.

### 3. Shared types (cluster-scoped, authored once)

The ComponentTypes / ResourceTypes / Traits the import needs, authored at cluster scope (`ClusterComponentType` / `ClusterResourceType` / `ClusterTrait`) so any namespace can reference them. Namespaced variants exist (`ComponentType` / `ResourceType` / `Trait`) if a type should be scoped to one namespace; use sparingly.

Recommend authoring at the pattern level. The plan lists the CTs / RTs / Traits the import needs, each alongside the Components / Resources that share it. List each as "to author" with enough detail to write the YAML later.

#### For each ComponentType to author

- `name` and kind (`ClusterComponentType` vs `ComponentType`).
- `spec.workloadType`: one of `deployment` | `statefulset` | `cronjob` | `job` | `proxy`.
- `spec.allowedWorkflows[]`: `{kind, name}` of each CI workflow this CT supports (only relevant for from-source components — drives 1.4).
- `spec.allowedTraits[]`: `{kind, name}` of each Trait that may attach to this CT.
- `spec.parameters` (OpenAPIv3 schema): developer-facing knobs on the Component (often empty for simple CTs).
- `spec.environmentConfigs` (OpenAPIv3 schema): per-env override surface (typically `replicas`, `resources` requests/limits, `imagePullPolicy` — but it's whatever the CT exposes).
- `spec.validations[]`: list each CEL `rule` + `message` in plain English (e.g. "Service components must have at least one endpoint", "external visibility requires `gateway.ingress.external`").
- `spec.resources[]`: enumerate every `id` the CT renders and what K8s it produces (shape reference: `references/sample-types/component-types/`). For each: note `includeWhen` / `forEach` gating and what fields are templated from `workload` / `parameters` / `environmentConfigs` / `gateway` / `dependencies`.

#### For each ResourceType to author

- `name` and kind (`ClusterResourceType` vs `ResourceType`).
- **What it must reproduce** (decides reuse vs. author) — the backing image (a vanilla engine vs a project-specific image with schema / seed data baked into init), the init env those scripts gate on (e.g. a demo-data or bootstrap flag), and the credential / output semantics the app expects (a whole connection URL vs host + port + user + password, and the exact URL scheme). A shipped RT is reusable only if it satisfies these; otherwise author a tailored one. State that verdict here rather than assuming a generic engine RT suffices.
- **Implementation strategy** — from 1.3 (in-cluster primitives / Crossplane / cloud operator / Terraform-via-Workflow / already-managed). Names the templating mechanism the `resources[]` below use.
- `spec.parameters` (OpenAPIv3 schema): developer-facing (e.g. `database` name, engine version, sizing tier).
- `spec.environmentConfigs` (OpenAPIv3 schema): per-env (e.g. `memory`, `replicas`, `adminEnabled`).
- `spec.retainPolicy`: `Delete` (cascade on unbind) or `Retain` (keep the provisioned infra).
- `spec.outputs[]`: the consumer wiring contract — each output has a `name` plus a source: a literal CEL `value:`, a `configMapKeyRef: {name, key}` to a rendered ConfigMap, or a `secretKeyRef: {name, key}` to a rendered Secret / ExternalSecret. Typical outputs: `host`, `port`, `database`, `username`, `password`, `url`. **Mark which are secret-backed** — Workloads bind them via `fileBindings` or env vars.
- `spec.resources[]`: enumerate every `id` and what each provisions (shape reference: `references/sample-types/resource-types/postgres.yaml`). Note `includeWhen` / `readyWhen` per `id`. (If 1.3 picked **already-managed**, `resources[]` may be empty and `outputs[]` references a pre-existing SecretReference / ConfigMap.)

#### For each Trait to author

- `name` and kind (`ClusterTrait` vs `Trait`).
- `spec.parameters` (OpenAPIv3 schema): Trait-instance config.
- `spec.environmentConfigs` (OpenAPIv3 schema): per-env override (`enabled`, channels, etc.).
- `spec.validations[]`: CEL rules + plain-English messages.
- `spec.creates[]`: new K8s resources the Trait emits. Each entry: `targetPlane` (`dataplane` | `observabilityplane`, defaults to `dataplane`), optional `includeWhen`, plus the templated resource. E.g. an alerting Trait that creates an `ObservabilityAlertRule` on the observability plane, gated by `has(dataplane.observabilityPlaneRef)`.
- `spec.patches[]`: RFC-6902 ops (`op: add|replace|remove`, `path`, `value`) on resources the Component's CT already rendered. E.g. a `persistent-volume` Trait might `add` a `volumeMounts` entry to the Deployment's main container and `add` a `volumes` entry to the pod spec, plus `creates` a PVC.

Don't dump full CEL templates inline — describe each `id`'s purpose and the load-bearing fields. The plan's reader writes the YAML using `references/sample-types/` as structural reference. **In the plan text, every CT / RT / Trait is "to author" — never "the shipped X"; the plan can't know what the target install ships.**

### 4. Migration order

**This is the spine.** Each per-Project section below is a self-contained migration unit — apply it, work through its *Definition of done*, then start the next.

**Build once, promote everywhere.** Each Component's `ComponentRelease` is an immutable snapshot — the controller cuts one when the Component / Workload spec changes. Promotion across environments is **per-env ReleaseBindings pinning the same release**, with per-env override buckets (`componentTypeEnvironmentConfigs` / `traitEnvironmentConfigs` / `workloadOverrides`) supplying the knobs. The same release pin moves through the pipeline — no rebuild per env. (Same shape for Resources: one `ResourceRelease`, per-env `ResourceReleaseBinding`s.)

Project order is determined by **inter-project dependencies**. If Project A's Component calls a Project B endpoint (`dependencies.endpoints[].project: "B"`), Project B must be applied and its endpoints Ready first. The plan documents each cross-project edge and the resulting order. When two projects have no cross-edges, either order works — call that out so the migrator knows the choice is open.

**Peers not in this import.** If a Component calls a peer service that isn't being onboarded in this migration (a later phase, or a permanent legacy peer), model it as **external egress** in the per-Project section — a literal `container.env` entry with the peer's current URL as `value:` (credentials via a SecretReference if any). The caller's render gate then doesn't depend on something that doesn't exist on the platform yet. When/if the peer is later onboarded, the swap is: drop the literal env var, add a `dependencies.endpoints[]` entry `{component, project: "<peer-project>", envBindings: …}`, and the controller cuts a new ComponentRelease the binding picks up. **Tag those egress entries explicitly as *candidate peer — swap to `calls` when onboarded*** so the future swap is visible in the plan rather than buried as a permanent legacy URL.

### 5, 6, … — one section per Project (Cell)

One section per Project in the order from 4. Each Project is a self-contained migration unit: apply through its *Apply sequence*, validate per its *Definition of done*, then start the next .

#### Purpose
One or two sentences on what this Cell is — the bounded context (a domain, a team's app, a sub-system). Why these Components group together.

#### Project CR
```yaml
apiVersion: openchoreo.dev/v1alpha1
kind: Project
metadata:
  name: <project-name>
  namespace: <ns>
  annotations:
    openchoreo.dev/display-name: <display>
    openchoreo.dev/description: <short>
  labels:
    openchoreo.dev/name: <project-name>
spec:
  deploymentPipelineRef:
    name: <pipeline-from-2>
```

#### Types this project introduces (if any beyond 3)
List any ComponentType / ResourceType / Trait specific to this project (or shared but not yet covered in 3), using the same authoring detail (parameters / environmentConfigs / resources[] / outputs[] / validations[] / creates[] / patches[]) as 3. If nothing — say so explicitly.

#### Secrets — seed + reference
For each secret the project's Workloads need, **the plan covers both halves**: seeding the actual secret material in the external store (per 1.2), and declaring the `SecretReference` that points at it.

**Step 1 — seed the secret material** using the mechanism picked in 1.2. For `occ secret create`:
```bash
occ secret create generic <secret-name> \
  --namespace <project-ns> \
  --target-plane DataPlane/<dp-name> \
  --from-literal=<k>=<v> --from-literal=<k>=<v>
```
(Use `--category git-credentials` and `--target-plane ClusterWorkflowPlane/<wp>` for git creds; `docker-registry` / `tls` subcommands for those types.)

**Step 2 — declare a `SecretReference`** in the project's namespace (one CR per secret group):
```yaml
apiVersion: openchoreo.dev/v1alpha1
kind: SecretReference
metadata:
  name: <secret-name>
  namespace: <project-ns>
spec:
  targetPlane:
    kind: DataPlane            # or ClusterDataPlane / WorkflowPlane / ClusterWorkflowPlane
    name: <plane-name>
  template:
    type: Opaque               # or kubernetes.io/dockerconfigjson | tls | basic-auth | ssh-auth
  data:
    - secretKey: <k8s-secret-key>
      remoteRef:
        key: <path-in-external-store>     # e.g. secret/data/<app>/db
        property: <field>                 # e.g. password
  refreshInterval: 1h
```

**Step 3 — the Workload consumes it** via `dependencies.resources[]` envBindings (or fileBindings) below — the SecretReference resolves to a K8s Secret on the target plane, which the Workload mounts.

For each secret in this project, the plan lists: name, target plane, what fields it holds, which Workloads consume it.

#### Components + Workloads
For each Component in this project:

- **Component** (`spec.componentType {kind, name}` in `{workloadType}/{typeName}` form, e.g. `deployment/service`, `kind: ClusterComponentType`; `spec.parameters`; `spec.traits[]` — each `{kind, name, instanceName, parameters}`; `spec.autoDeploy` (typically `true` for app workloads, `false` for shared infra the migrator wants to roll out deliberately)). Note the requirement that fixes the chosen ComponentType — a browser-facing UI needs root-host routing (so its absolute paths like `/login` resolve), an API is fine on path/host routing; this is why two superficially similar workloads may not share one CT.
- **Workload** (1:1 with its Component):
  - `spec.container` — `image` (and `command`/`args` if explicit).
  - `spec.endpoints` (map keyed by endpoint name) — each: `type` (`HTTP` | `gRPC` | `GraphQL` | `Websocket` | `TCP` | `UDP`), `port`, `targetPort`, `visibility[]` (`project` implicit; add `namespace` / `internal` / `external`), `basePath`. **List every endpoint with port + visibility.**
  - `spec.dependencies.endpoints[]` — calls to other Components: `{component, name (target endpoint), visibility (project|namespace), project (if cross-project — see 4), envBindings: {address|host|port|basePath → ENV_VAR}}`. The platform resolves the in-cluster address into the named env var.
  - `spec.dependencies.resources[]` — managed-infra use: `{ref (Resource name), envBindings: {<RT output> → ENV_VAR}, fileBindings: {<RT output> → /path/in/container}}`. **List which outputs (`host`/`port`/`username`/`password`/`url`/…) bind to which env var or file.**
  - **Sizing** (per workload, from source — never generalized across siblings) — resource requests / limits (CPU *and* memory). Not a Workload-spec field; supplied through the ComponentType's `environmentConfigs`. **Use the source-declared values. If the source declares none, pick a plausible default for the workload class — never inherit a generic ComponentType's defaults, which are demo-grade and under-provision.** Since the import typically authors a tailored ComponentType for the app, bake these into its `environmentConfigs` defaults so every component and environment inherits them. (Other settings the Workload spec doesn't carry — probes, security context, init containers, and the like — become a ComponentType field or a Trait per *Types this project introduces*; read them per workload too, don't generalize across siblings.)

#### Resources
For each platform-managed dependency in this project:
- **Resource** (`spec.type {kind, name}` — the ResourceType from 3 or *types this project introduces*; `spec.owner.projectName`; `spec.parameters` per the RT's schema).
- Resources **live in the same Project as their consumers** — cross-project Resource consumption is not supported.

#### Bindings (per env, per Component / Resource)
- **ReleaseBinding** — per Component, per Environment. Auto-created for the first env when `autoDeploy: true`; otherwise authored per env. Three override buckets (see [`concepts.md`](concepts.md) → *Per-environment overrides*):
  - `componentTypeEnvironmentConfigs` — the CT's environmentConfigs schema (replicas, resources, ports — schema-driven).
  - `traitEnvironmentConfigs` — per Trait instance, keyed by `instanceName` (e.g. `{"alert-error-rate": {threshold: 50}}`).
  - `workloadOverrides` — container env vars / file mounts (direct, not schema-driven; use for per-env URLs and the like that don't belong in the authored Workload).
  List each env's overrides for each Component.
- **ResourceReleaseBinding** — per Resource, per Environment. **Always authored explicitly**, one per env, with `spec.resourceRelease` pinned/promoted manually. Carries `retainPolicy` (`Delete` | `Retain`) and `resourceTypeEnvironmentConfigs`. List each binding's pinned release + per-env config.
- **`ComponentRelease` / `ResourceRelease`** are **controller-generated** immutable snapshots — reference them, never author them. (Cut automatically on Component / Workload / Resource spec change.)

#### Apply sequence (this project)
1. **Seed the secret material** in the external store for every SecretReference the project's Workloads or builds need (per 1.2).
2. **Apply the `SecretReference` CRs**.
3. **Apply the `Project` CR** — it owns everything below.
4. **Apply the `Resource` CRs** (one per managed dep).
5. **Apply Components + Workloads together** — controllers auto-cut a `ComponentRelease` (and `ResourceRelease`s).
6. **Author `ResourceReleaseBinding`s** — one per resource per env, pinning `spec.resourceRelease` to the resource's latest release.
7. **Deploy to the first environment** — `autoDeploy: true` auto-creates the first `ReleaseBinding`; otherwise author it.
8. **Promote** along the DeploymentPipeline to the next envs (one `ReleaseBinding` per env; the same immutable release).

Note **render gating**: a Component isn't deployed until its declared endpoint and resource dependencies report Ready — so Resources / ResourceReleaseBindings must precede the Components that consume them, and called-Project endpoints must be Ready before the caller is deployed.

#### Definition of done
Before starting the next project, verify:

- `kubectl get releasebindings -n <ns> -o wide` shows all `Ready` for every Environment this project deploys to.
- `kubectl get resourcereleasebindings -n <ns>` shows all `Ready` for every Resource.
- Each Component endpoint smoke-tests at its visibility-appropriate URL (the gateway URL for `external`/`internal`; the in-cluster Service for `project`/`namespace`). For a browser-facing app, exercise the **real entry path a user hits** — the app's own external URL, following its redirects — not just an internal probe; the two can diverge, so an internal check can pass while the user-facing route fails.
- **Project-specific functional check** — list one or two concrete behaviors the migrator should trigger (a login flow completes, an ingest job produces output to the database, a webhook fires correctly, etc.). The plan must spell these out per project, not leave them generic. Run the check more than once, exercising the real entry path a user hits — a result that passes once can still fail on a fresh or first request.

If any of these fail, fix here — don't start the next project until this one passes.

## What to omit
- **"What we mapped"** and **"what the platform handles by default"** framing — the migration plan says what to *do*, not what was inferred or what's automatic.
- The fit verdict / source recap — the verdict was delivered in chat; don't re-litigate it here.
- Full generated CR YAML inline — describe each resource and its load-bearing fields (above); the apply tooling produces the manifests.
- Specific applying skills / tools by name — the plan stays tool-agnostic.
- Status-tracking tables / progress checkboxes — the plan is the plan; the cluster + whatever the migrator uses externally is where lifecycle lives.
