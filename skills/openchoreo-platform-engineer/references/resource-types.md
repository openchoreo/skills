# ResourceTypes

This file is the authoring reference for **ResourceTypes** and **ClusterResourceTypes** — the resources platform engineers create so developers can request managed infrastructure (databases, queues, caches, object storage, etc.) the way they request deployment templates.

For the CEL expressions used throughout, see [`cel.md`](./cel.md). For the ComponentType / Trait syntax systems reused here (templating, schema), see [`component-types-and-traits.md`](./component-types-and-traits.md). The full MCP tool list is discovered at runtime via the control-plane MCP server.

**Tool surface for these resources:** MCP-first, and **scope-collapsed** — `create_resource_type` / `get_resource_type` / `update_resource_type` / `delete_resource_type` / `list_resource_types` each take a `scope` arg: `"namespace"` (default; the namespaced `ResourceType` in `namespace_name`) or `"cluster"` (the platform-wide `ClusterResourceType`). So `create_resource_type` with `scope: "cluster"` authors a `ClusterResourceType`. Discover the spec body via `get_resource_type_creation_schema` (also `scope`-aware). `update_*` is **full-spec replacement**: read the current spec via `get_resource_type` first, modify locally, send the whole spec back. For one-line CEL or template tweaks, `kubectl apply -f` against an edited YAML is often easier; both paths are equivalent.

Contents:

1. Concepts — what a ResourceType is, scope rules, relationship to ComponentType
2. ResourceType authoring (skeleton, `parameters` / `environmentConfigs`, `resources[]`, `outputs[]`, `retainPolicy`)
3. CEL surface — which contexts are available where
4. `includeWhen` and `readyWhen` — conditional emit + readiness
5. Outputs — the three source kinds and the secret-on-DP discipline
6. How developers consume a ResourceType
7. Common patterns
8. Verification — MCP and `kubectl` flows

---

## 1. Concepts

| Resource | Scope | Defines |
|---|---|---|
| `ResourceType` | namespace | Parameter schema, per-env config schema, manifest templates, outputs, retainPolicy default |
| `ClusterResourceType` | cluster-wide | Same shape; available in every namespace |

A ResourceType is to managed infrastructure what a ComponentType is to code components. It captures the manifests the platform emits, the parameters developers can supply, the environment-specific overrides bindings can apply, and the named outputs consumers wire into their containers.

### Scope rules

- `ResourceType` and `ClusterResourceType` are **interchangeable in shape**. Convert by swapping `kind:` and adding / removing `metadata.namespace:`.
- A `ClusterResourceType` may only emit cluster-scoped manifests or namespace-scoped manifests that pick their target namespace from `${metadata.namespace}` (the platform-resolved namespace for the binding). A namespace-scoped `ResourceType` is also free to target the binding namespace this way.
- Cluster-scoped CRDs **must omit** `metadata.namespace`; namespace-scoped CRDs **must include** it.

### Where ResourceType sits in the deploy flow

Mirror of the component-side flow:

```
Resource (developer) → ResourceRelease (auto-cut, immutable) →
  ResourceReleaseBinding (per-env) → RenderedRelease (on DataPlane) → actual K8s objects
```

Developer authors a `Resource` referencing a ResourceType + parameters. The Resource controller cuts an immutable `ResourceRelease` (snapshot of `{Resource.spec, ResourceType.spec}`). A `ResourceReleaseBinding` per environment pins a `ResourceRelease` and triggers the actual deploy — authored explicitly via `create_resource_release_binding`, the Backstage UI's Deploy action, or a GitOps commit (PE / GitOps owns the lifecycle in practice, but the surface is open to dev too). The Resource controller never fans bindings out automatically. The binding controller renders the ResourceType's templates with the snapshot + env overrides, applies the result to the data plane, then surfaces declared outputs on `status.outputs` so consuming Workloads can read them.

### Defaults that ship

Default installs include three `ClusterResourceType`s under `samples/getting-started/cluster-resource-types/`: `postgres`, `valkey`, `nats`. Each demonstrates the full pattern (ESO-generated credentials on the DP, conditional admin UI via `includeWhen`, `readyWhen` against the underlying StatefulSet / Deployment). Useful as reference templates; **not intended for production** — they back stateful infra with in-cluster StatefulSets. Production templates typically target a managed-provisioner abstraction (Crossplane, ACK, native cloud operator) instead.

---

## 2. ResourceType authoring

### Skeleton

```yaml
apiVersion: openchoreo.dev/v1alpha1
kind: ResourceType                       # or ClusterResourceType
metadata:
  name: valkey-cache
  namespace: default                     # omit for ClusterResourceType
spec:
  # Developer-facing parameters; frozen into the ResourceRelease snapshot.
  parameters:
    openAPIV3Schema:
      type: object
      properties: { ... }                # see Schema syntax in component-types-and-traits.md 4

  # Per-environment overrides applied through ResourceReleaseBinding.
  environmentConfigs:
    openAPIV3Schema:
      type: object
      properties: { ... }                # same shape as parameters

  # Default deletion behavior. Bindings can override per-env.
  retainPolicy: Delete                   # or Retain

  # Named values consumers wire into containers.
  outputs:
    - name: host
      value: "${metadata.name}.${metadata.namespace}.svc.cluster.local"
    - name: password
      secretKeyRef:
        name: "${metadata.name}-creds"
        key: password

  # Kubernetes manifests rendered onto the data plane.
  resources:
    - id: password-secret
      template: { ... }                  # Kubernetes resource with CEL expressions
    - id: service
      template: { ... }
    - id: statefulset
      readyWhen: "${applied.statefulset.status.readyReplicas == applied.statefulset.status.replicas && applied.statefulset.status.replicas > 0}"
      template: { ... }
```

### `parameters` vs `environmentConfigs`

- **`parameters`** — values from `Resource.spec.parameters`. **Static across environments.** Frozen into the `ResourceRelease` snapshot at the moment the controller cuts the release. Editing `Resource.spec.parameters` cuts a new release; existing bindings stay pinned until promoted.
- **`environmentConfigs`** — values from `ResourceReleaseBinding.spec.resourceTypeEnvironmentConfigs`. **Per-environment.** Re-evaluated on every binding reconcile; changes do not require a new release, just an update to the binding.

Both use the same `openAPIV3Schema` shape documented in [`component-types-and-traits.md`](./component-types-and-traits.md) 4. Same validation rules, same defaulting, same `x-oc-*` extension fields. Defaults are applied before CEL evaluation, so `${parameters.version}` resolves to the schema default when the developer omits the field.

### `retainPolicy`

`Delete` (default) or `Retain`. PE default for what happens on `ResourceReleaseBinding` deletion. Per-env override lives on `ResourceReleaseBinding.spec.retainPolicy`.

- `Delete` — binding finalizer removes the emitted data-plane manifests on delete.
- `Retain` — binding finalizer holds when deleted, preserving the data-plane state until the policy flips back to `Delete`.

Common pattern: PE leaves the type at `Delete` (safe default for dev/staging); the prod binding overrides to `Retain` so a Git-side delete doesn't cascade through and destroy a database.

### `resources[]`

List of named manifest entries, each with a stable `id` referenced by `outputs[]` and `readyWhen`. Entries render in spec order. Each entry has:

- `id` — unique identifier (string, required). Outputs and `readyWhen` reference entries by this id; the rendered K8s object's `metadata.name` is unrelated.
- `template` — the K8s manifest, with `${...}` CEL substitutions throughout.
- `includeWhen` (optional) — boolean CEL; when `false`, the entry is omitted from the rendered output and any previously-applied object is GC'd from the data plane.
- `readyWhen` (optional) — boolean CEL; when set, replaces the default per-Kind health heuristic for this entry's contribution to `ResourcesReady`.

### `outputs[]`

List of named values consumers bind via `Workload.spec.dependencies.resources[].envBindings` / `.fileBindings`. Each output has a unique `name` and exactly one source kind: `value`, `secretKeyRef`, or `configMapKeyRef`. See 5 for the contract and security model.

---

## 3. CEL surface

Available CEL bindings depend on which field is being evaluated:

| Context | template | includeWhen | readyWhen | outputs | Description |
|---|:---:|:---:|:---:|:---:|---|
| `metadata.*` | yes | yes | yes | yes | Platform-injected: `name`, `namespace`, `resourceName`, `resourceNamespace`, `resourceUID`, `projectName`, `projectUID`, `environmentName`, `environmentUID`, `dataPlaneName`, `dataPlaneUID`, `labels`, `annotations` |
| `parameters.*` | yes | yes | yes | yes | `Resource.spec.parameters` after schema defaulting |
| `environmentConfigs.*` | yes | yes | yes | yes | `ResourceReleaseBinding.spec.resourceTypeEnvironmentConfigs` after defaulting |
| `environment.*` | yes | yes | yes | yes | Environment surface including merged effective gateway |
| `dataplane.*` | yes | yes | yes | yes | Target DataPlane attrs: `secretStore`, `observabilityPlaneRef`, `gateway` |
| `gateway.*` | yes | yes | yes | yes | Effective gateway (Environment-level merged onto DataPlane-level fallback) |
| `applied.<id>.*` | **no** | **no** | yes | yes | Status of applied DP resources, keyed by template `id` |

`applied.<id>.*` is not available during rendering — the manifests have not been applied yet. It becomes available in `readyWhen` and `outputs` because both run after the data plane reports back. Use `applied.<id>.status.*` in outputs to surface provider-populated fields (e.g., a Crossplane claim's connection details).

The `${...}` wrapper is required on `includeWhen`, `readyWhen`, `outputs[].value`, `outputs[].secretKeyRef.{name,key}`, and `outputs[].configMapKeyRef.{name,key}`. Inside resource templates, both `${...}` string interpolation and whole-field `${...}` replacement work — same shape as ComponentType templates.

### Forward-compat boundary

`metadata.componentName`, `metadata.componentUID`, `metadata.podSelectors`, `configurations.*`, `dependencies.*`, `workload.*` are **not in scope** for ResourceType templates — references will fail validation. These surfaces belong to ComponentType templates because a Resource has no consuming Component context at render time (Resources are shared across consumers in a Project+Env).

---

## 4. `includeWhen` and `readyWhen`

Each `resources[]` entry supports two optional boolean CEL fields shaping its lifecycle.

### `includeWhen`

Evaluated **at render time**. When `false`, the entry is omitted from the rendered output and any previously-applied object is garbage-collected from the data plane on the next reconcile. Common uses:

```yaml
# Conditionally emit a Certificate when TLS is requested
- id: cert
  includeWhen: "${parameters.tlsEnabled}"
  template: { kind: Certificate, ... }

# Only emit the admin UI when explicitly enabled AND the env has external ingress
- id: admin-route
  includeWhen: "${environmentConfigs.adminEnabled && has(gateway.ingress.external)}"
  template: { kind: HTTPRoute, ... }
```

`includeWhen` cannot reference `applied.*` — the entry might not be applied yet. If you need a runtime signal to gate inclusion, you've usually wired the dependency wrong.

### `readyWhen`

Evaluated **after the rendered object is applied**, on each reconcile. When `true`, the entry contributes positively to the binding's `ResourcesReady` condition. When unset, the binding falls back to the per-Kind health heuristics in `RenderedRelease` (replica counts, condition probes — good enough for Deployment / StatefulSet / Job / ConfigMap / Secret out of the box).

Set `readyWhen` when the default heuristic doesn't match your provisioner's signal:

```yaml
# Crossplane claim's Ready condition
- id: db-claim
  readyWhen: "${applied.db-claim.status.conditions.exists(c, c.type == 'Ready' && c.status == 'True')}"
  template: { ... }

# Explicit StatefulSet quorum (works even when replicas=1)
- id: statefulset
  readyWhen: "${applied.statefulset.status.readyReplicas == applied.statefulset.status.replicas && applied.statefulset.status.replicas > 0}"
  template: { ... }
```

Both fields must evaluate to a boolean and must be wrapped in `${...}`.

---

## 5. Outputs

Outputs are the contract between the ResourceType and the consuming Workloads. Each output is identified by a unique `name` and picks exactly one source kind:

| Source kind | When to use | What transits to the control plane |
|---|---|---|
| `value` | Non-sensitive data (host, port, region, database name, composed connection URLs) | The resolved literal value. Stored on `ResourceReleaseBinding.status.outputs[].value`. |
| `secretKeyRef` | Sensitive credentials (passwords, tokens, private keys) | Only `{name, key}` of the data-plane Secret. The underlying value never leaves the data plane. |
| `configMapKeyRef` | Non-sensitive runtime config sourced from a DP ConfigMap (CA bundles, locale settings) | Only `{name, key}` of the data-plane ConfigMap. |

### Examples

```yaml
outputs:
  # Literal value composed from metadata
  - name: host
    value: "${metadata.name}.${metadata.namespace}.svc.cluster.local"

  # CEL-templated name + key — both must resolve at the data plane
  - name: password
    secretKeyRef:
      name: "${metadata.name}-creds"
      key: password

  # Composite URL stitched from generated parts (e.g. NATS auth token)
  - name: url
    value: "nats://${metadata.name}:${metadata.name}.${metadata.namespace}.svc.cluster.local:4222"

  # ConfigMap-backed CA bundle
  - name: ca-cert
    configMapKeyRef:
      name: "${metadata.name}-ca"
      key: ca.crt
```

### Provider-populated outputs

For provisioners that emit credentials data-plane-side (Crossplane connection details, generated passwords), use `${applied.<id>.status.*}` in the output to surface the values the provisioner produced:

```yaml
outputs:
  - name: connectionString
    secretKeyRef:
      name: "${applied.db-claim.status.connectionDetails.secretName}"
      key: connection-string
```

### Hardening

- **Never put a credential in a `value:` output.** It resolves on the control plane and persists on the binding's `status.outputs[].value`. Anyone with read access to the binding sees it. Use `secretKeyRef` for any sensitive material.
- **Generate credentials on the data plane.** Use an `ExternalSecret` + `Password` generator (ESO) so the literal password never round-trips through the CP. The samples under `samples/getting-started/cluster-resource-types/` show the pattern.
- **Outputs declared but not requested by a consumer are unused.** Outputs requested by a consumer but not declared on the ResourceType surface as `ResourceDependenciesPending` on the consuming `ReleaseBinding`.

---

## 6. How developers consume a ResourceType

A developer creates a `Resource` referencing the ResourceType:

```yaml
apiVersion: openchoreo.dev/v1alpha1
kind: Resource
metadata:
  name: doclet-cache
  namespace: default
spec:
  owner:
    projectName: doclet
  type:
    kind: ResourceType                   # or ClusterResourceType
    name: valkey-cache
  parameters:
    version: "8"
```

Then declares a dependency from a Workload to the Resource and binds the outputs they need:

```yaml
apiVersion: openchoreo.dev/v1alpha1
kind: Workload
metadata:
  name: doclet-document
spec:
  owner:
    projectName: doclet
    componentName: doclet-document
  container:
    image: ghcr.io/openchoreo/samples/doclet-document:latest
  dependencies:
    resources:
      - ref: doclet-cache
        envBindings:
          host: REDIS_HOST
          port: REDIS_PORT
          password: REDIS_PASSWORD
```

PE / GitOps creates a `ResourceReleaseBinding` per environment to actually deploy:

```yaml
apiVersion: openchoreo.dev/v1alpha1
kind: ResourceReleaseBinding
metadata:
  name: doclet-cache-production
spec:
  owner:
    projectName: doclet
    resourceName: doclet-cache
  environment: production
  resourceRelease: doclet-cache-abc12345 # advance with `occ resource promote`
  retainPolicy: Retain                   # override the type's default for prod
  resourceTypeEnvironmentConfigs:
    memory: "2Gi"
```

`fileBindings` are also supported — they map a `secretKeyRef` / `configMapKeyRef` output to a file mount path on the consumer container. `value:` outputs cannot be mounted as files (no DP-side object to mount).

---

## 7. Common patterns

### ESO-generated credentials (never on the CP)

The shipped `valkey` / `postgres` / `nats` ClusterResourceTypes use this pattern. Two manifests cooperate: a `Password` generator emits a random secret on the DP; an `ExternalSecret` materializes it into a K8s Secret that the workload references. The CRT's `outputs[].secretKeyRef` only carries the Secret's `{name, key}` — the literal password never reaches the control plane.

```yaml
resources:
  - id: password-generator
    template:
      apiVersion: generators.external-secrets.io/v1
      kind: Password
      metadata:
        name: ${metadata.name}-pw-gen
        namespace: ${metadata.namespace}
      spec:
        length: 24
        digits: 5
        symbols: 0
        noUpper: false
        allowRepeat: true

  - id: password-secret
    template:
      apiVersion: external-secrets.io/v1
      kind: ExternalSecret
      metadata:
        name: ${metadata.name}-creds
        namespace: ${metadata.namespace}
      spec:
        refreshInterval: "0"          # critical: stateless generator; non-zero rotates the password
        target:
          name: ${metadata.name}-creds
          template:
            data:
              password: "{{ .password }}"
        dataFrom:
          - sourceRef:
              generatorRef:
                apiVersion: generators.external-secrets.io/v1
                kind: Password
                name: ${metadata.name}-pw-gen
```

Critical detail: **`refreshInterval: "0"`** on the ExternalSecret. The Password generator is stateless — every call returns a new random value. Any non-zero refresh interval rotates the password and desyncs running consumers whose env vars resolved at pod-start.

### Optional admin UI via `includeWhen` + `environmentConfigs`

PE wants admin tooling (Adminer for postgres, NATS `/varz`) available in dev but not prod. Wire it as an opt-in env config:

```yaml
spec:
  environmentConfigs:
    openAPIV3Schema:
      type: object
      properties:
        adminEnabled:
          type: boolean
          default: false

  resources:
    - id: admin-deployment
      includeWhen: "${environmentConfigs.adminEnabled}"
      template: { kind: Deployment, ... }

    - id: admin-route
      includeWhen: "${environmentConfigs.adminEnabled && has(gateway.ingress.external)}"
      template: { kind: HTTPRoute, ... }
```

Dev binding sets `resourceTypeEnvironmentConfigs.adminEnabled: true`; prod binding leaves it default. Flipping it off later GCs the admin manifests cleanly.

### Composite URL output

When the consumer expects a single connection string rather than parts, compose the URL `value:` on the CRT (DP-side via ESO `target.template` if it includes credentials):

```yaml
outputs:
  - name: url
    secretKeyRef:                       # composed in the Secret on the DP
      name: ${metadata.name}-conn
      key: url
```

Then the `ExternalSecret.spec.target.template` stitches `{{ .password }}` into a `postgres://user:{{ .password }}@host:5432/db` string on the data plane. CP only sees the `{name, key}` reference.

### `readyWhen` for stateful infra

Default per-Kind health heuristics catch most cases, but stateful workloads with quorum requirements (Postgres, NATS clusters) benefit from explicit readiness:

```yaml
- id: statefulset
  readyWhen: "${applied.statefulset.status.readyReplicas == applied.statefulset.status.replicas && applied.statefulset.status.replicas > 0}"
  template: { kind: StatefulSet, ... }
```

The `> 0` guard avoids a false-positive when `replicas == 0` (a paused resource shouldn't report Ready).

### Crossplane-backed ResourceType

For production resources, target a managed-provisioner abstraction. The ResourceType emits a Crossplane Claim; outputs surface fields from the claim's `status.connectionDetails`:

```yaml
resources:
  - id: claim
    readyWhen: "${applied.claim.status.conditions.exists(c, c.type == 'Ready' && c.status == 'True')}"
    template:
      apiVersion: database.example.org/v1alpha1
      kind: PostgresClaim
      metadata:
        name: ${metadata.name}
        namespace: ${metadata.namespace}
      spec:
        parameters:
          storageGB: ${parameters.storageGB}
        writeConnectionSecretToRef:
          name: ${metadata.name}-conn

outputs:
  - name: host
    secretKeyRef:
      name: "${metadata.name}-conn"
      key: endpoint
  - name: password
    secretKeyRef:
      name: "${metadata.name}-conn"
      key: password
```

The Crossplane integration guide on the docs site is the source of truth for the provisioner side; this skill only owns the ResourceType authoring shape.

---

## 8. Verification

After authoring a ResourceType, walk the chain in order:

1. **Type accepted by the webhook** — `get_resource_type` (with `scope`) returns the spec without `status.conditions[Ready]=False`. CRT-level CEL parse / output declaration errors surface here.
2. **Schema discoverable** — `get_resource_type_schema` returns the parameter schema. This is what the dev side calls when authoring a Resource.
3. **A test Resource cuts a release** — create a `Resource` against the new type; `Resource.status.latestRelease.name` populates within a reconcile.
4. **A test binding renders cleanly** — `ResourceReleaseBinding.status.conditions[Synced]=True, Reason=ReleaseSynced`. `RenderingFailed` surfaces here for CEL eval errors that depend on runtime values (e.g., a missing `parameters` field at use-site).
5. **Data-plane objects exist** — drop to `kubectl` on the relevant data plane: the rendered Secret / Service / StatefulSet / etc. should be present in the project-env namespace.
6. **Outputs resolved** — `ResourceReleaseBinding.status.outputs[]` carries the declared output names with non-empty `value` / `secretKeyRef.{name,key}` / `configMapKeyRef.{name,key}`. `OutputsResolved=False` here usually means a typo in the output expression (e.g. `applied.statfulset` instead of `applied.statefulset`).
7. **End-to-end consumer** — create a Workload with `dependencies.resources[].envBindings` referring to one of the outputs; the consumer `ReleaseBinding` should reach `Ready=True` with `ResourceDependenciesReady=True`. If `False`, the per-entry breakdown is on `status.pendingResourceDependencies[]`.

### When the type doesn't render

Common failure modes on the consuming `ResourceReleaseBinding`:

- **`Synced=False, Reason=RenderingFailed`** — CEL eval error at render time. Check the condition message; usually a missing field in `parameters` / `environmentConfigs` after defaulting, or a reference to a field outside the CEL surface for `template` / `includeWhen` (e.g., `applied.*` in a template).
- **`Synced=False, Reason=ReleaseOwnershipConflict`** — a `RenderedRelease` with the same name already exists owned by something else (typically a Component named the same as the Resource). Resource-side rendered names carry an `r-` prefix to avoid this; if you hit it, two Resources collided on hash.
- **Other `Synced=False` reasons** flag earlier-chain problems: `ResourceReleaseNotSet`, `ResourceReleaseNotFound`, `InvalidReleaseConfiguration`, `EnvironmentNotFound`, `DataPlaneNotFound`, `ResourceNotFound`, `ProjectNotFound`. Each names what's missing.
- **`ResourcesReady=False, Reason=ResourcesDegraded`** — a rendered manifest applied but its per-Kind health probe reports Degraded (e.g., Deployment with `progressDeadlineSeconds` exhausted on a bad image). Drop to `kubectl describe` / `kubectl logs` on the data plane.
- **`ResourcesReady=False, Reason=ResourcesProgressing`** — manifest applied but not Ready yet (rolling). Wait, then re-check.
- **`ResourcesReady=False, Reason=ResourceApplyFailed`** — the `RenderedRelease` controller couldn't apply a manifest on the data plane (cluster-agent connectivity, RBAC, K8s validation). Check `RenderedRelease.status` on the CP and `kubectl describe` on the DP.
- **`OutputsResolved=False, Reason=OutputResolutionFailed`** — output CEL refers to a path not present in `applied.<id>.status.*`. Check the actual status shape with `kubectl get <kind> -o jsonpath='{.status}'`.

> **Parameter-schema mismatches show up as webhook admission errors**, not as a `Synced` reason. If `Resource.spec.parameters` violates the type's `parameters.openAPIV3Schema`, `create_resource` / `update_resource` fails outright with a `field.Invalid` from the `resourcerelease` webhook (it validates the snapshot embedded in the cut release). The dev fixes the parameter or the PE relaxes the schema.

### `kubectl` quick reference

For when MCP doesn't expose what you need:

```bash
# CRT lookup
kubectl get clusterresourcetype <name> -o yaml
kubectl get resourcetype <name> -n <ns> -o yaml

# Cut releases for a Resource
kubectl get resourcerelease -n <ns> -l openchoreo.dev/resource=<resource>

# Rendered manifests on the data plane (against the DP's kubeconfig)
kubectl --context=<dp-context> get all -n <project>-<env>
```
