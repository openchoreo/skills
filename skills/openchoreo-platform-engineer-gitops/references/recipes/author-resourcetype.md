# Recipe — Author a (Cluster)ResourceType via Git

Define a managed-infrastructure template — parameter schema, per-env config schema, manifest templates (CEL), declared outputs, retention default. Commit, PR, reconcile.

Tweaking an existing ResourceType uses the same recipe — edit the file, commit, Flux re-applies the full spec.

## Scope decision

| Scope | When | Path |
| --- | --- | --- |
| `ClusterResourceType` (default) | Visible to every namespace — platform-wide infra catalog. | `platform-shared/resource-types/<name>.yaml` |
| `ResourceType` (namespace-scoped) | Tenant isolation, stricter parameter schemas, gradual rollout. | `namespaces/<ns>/platform/resource-types/<name>.yaml` |

**Cross-scope rule.** A `ClusterResourceType` may only emit cluster-scoped manifests or namespace-scoped manifests targeting `${metadata.namespace}` (the binding's project-env namespace). A namespace-scoped `ResourceType` is also free to target the binding namespace via the same CEL. **`metadata.namespace`:** cluster-scoped CRDs reject it; namespace-scoped CRDs require it.

## Steps

### 1. Decide what the type emits

Mirror of ComponentType's `workloadType` choice — but for a ResourceType the question is *what manifests do you render*. Three families in common use:

- **In-cluster StatefulSet/Deployment + ESO-generated creds** — the pattern the shipped defaults use (`postgres`, `valkey`, `nats`). Good for local dev; not production-grade for stateful infra.
- **Managed-provisioner claim** — emit a Crossplane / ACK / native operator claim. Outputs source from the claim's `status.connectionDetails`. Production-grade.
- **Pure cloud-API call via External Secrets** — emit an `ExternalSecret` referencing a pre-provisioned cloud resource (RDS, S3 bucket already created by infra-as-code).

### 2. Source the shape

Pick one per [`../authoring.md`](../authoring.md) *Shape-lookup*:

- **Full schema** — `./scripts/fetch-page.sh --exact --title "ClusterResourceType"` (or `"ResourceType"`).
- **Default for inspiration** — `./scripts/extract-resources.sh defaults --kind ClusterResourceType --name <postgres|valkey|nats>`.
- **What's installed on the live cluster** — `occ clusterresourcetype get <name>` / `occ resourcetype get <name> -n <ns>`.

If sourcing one scope but the user wants the other, apply the conversion in [`../authoring.md`](../authoring.md) *Cluster ↔ namespace scope*.

### 3. Compose

Five load-bearing fields:

- **`parameters.openAPIV3Schema`** — dev-facing knobs. Frozen into the `ResourceRelease` snapshot. Same schema dialect as ComponentType.
- **`environmentConfigs.openAPIV3Schema`** — per-env knobs (replica count, admin-tools-enabled, etc.). Re-evaluated on every binding reconcile.
- **`resources[]`** — K8s resource templates with CEL. Each has `id`, `template`, optional `includeWhen` / `readyWhen`.
- **`outputs[]`** — named values consumers wire into containers. Three source kinds: `value` / `secretKeyRef` / `configMapKeyRef`. Credentials must use a ref kind (DP-side); `value:` outputs persist literally on the binding's status.
- **`retainPolicy`** — `Delete` (default) or `Retain`. PE default; bindings can override per-env.

Skeleton:

```yaml
apiVersion: openchoreo.dev/v1alpha1
kind: ClusterResourceType
metadata:
  name: valkey-cache
spec:
  parameters:
    openAPIV3Schema:
      type: object
      properties:
        version:
          type: string
          enum: ["7", "8"]
          default: "8"

  environmentConfigs:
    openAPIV3Schema:
      type: object
      properties:
        memory: { type: string, default: "128Mi" }
        adminEnabled: { type: boolean, default: false }

  retainPolicy: Delete

  outputs:
    - name: host
      value: "${metadata.name}.${metadata.namespace}.svc.cluster.local"
    - name: port
      value: "6379"
    - name: password
      secretKeyRef:
        name: "${metadata.name}-creds"
        key: password

  resources:
    - id: password-secret
      template:
        apiVersion: external-secrets.io/v1
        kind: ExternalSecret
        metadata:
          name: ${metadata.name}-creds
          namespace: ${metadata.namespace}
        spec:
          refreshInterval: "0"                # stateless generator; non-zero rotates and desyncs
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

    - id: statefulset
      readyWhen: "${applied.statefulset.status.readyReplicas == applied.statefulset.status.replicas && applied.statefulset.status.replicas > 0}"
      template:
        apiVersion: apps/v1
        kind: StatefulSet
        metadata:
          name: ${metadata.name}
          namespace: ${metadata.namespace}
        spec:
          serviceName: ${metadata.name}
          replicas: 1
          # ...

    - id: admin-route
      includeWhen: "${environmentConfigs.adminEnabled && has(gateway.ingress.external)}"
      template:
        apiVersion: gateway.networking.k8s.io/v1
        kind: HTTPRoute
        # ...
```

For the full body (Password generator + Secret target template + StatefulSet container spec + Service + admin UI), start from a default extracted via `./scripts/extract-resources.sh defaults --kind ClusterResourceType --name <postgres|valkey|nats>` and adapt.

### 4. Commit + verify

Branch `platform/resourcetype-<name>-<ts>`, commit message `"platform: add <ClusterResourceType|ResourceType> <name>"`. Canonical flow in [`../authoring.md`](../authoring.md) *Git workflow*. After merge:

```bash
flux get kustomizations -A
occ clusterresourcetype get <name>            # or occ resourcetype get <name> -n <ns>
# status.conditions[Ready] should not be False — webhook surfaces CEL parse / output declaration errors here
```

### 5. Smoke test

Have a developer create a `Resource` referencing the new type, then a `ResourceReleaseBinding` for an env:

```yaml
spec:
  type:
    kind: ClusterResourceType
    name: valkey-cache
  parameters:
    version: "8"
```

Walk the chain:

```bash
occ resource get <r> -n <ns>                   # status.latestRelease.name populated
occ resourcereleasebinding get <r>-<env> -n <ns>
# Synced → ResourcesReady → OutputsResolved → Ready (all True)
# status.outputs[] populated with declared output names
```

If `Synced=False, Reason=RenderingFailed`, the CEL eval failed at render time — usually a missing field in `parameters` after defaulting, or an `applied.*` reference in a template (which is only in scope for `readyWhen` / `outputs`). If `OutputsResolved=False`, the output CEL refers to a path not present in `applied.<id>.status.*`. See [`../concepts.md`](../concepts.md) *Verification ladder*.

## Updating an existing ResourceType

Flux re-applies the full file every reconcile. **Anything not in the file is removed.** Don't half-edit.

**Edits cut new releases.** The Resource controller hashes `Resource.spec + ResourceType.spec`, so a PE edit to a popular `ClusterResourceType` cuts a new `ResourceRelease` on every consuming `Resource` across namespaces. Existing bindings stay pinned to the old release until promoted — but the moment a developer / GitOps process advances `ResourceReleaseBinding.spec.resourceRelease`, your edits go live in that env.

When publishing a backward-incompatible change (renamed output, removed parameter), version the type instead of editing in place — `valkey-cache-v2.yaml` alongside `valkey-cache.yaml`. Consumers migrate at their pace.

## Variants

**Namespace-scoped tenancy** — same shape, `kind: ResourceType`, set `metadata.namespace`, path `namespaces/<ns>/platform/resource-types/`. Resource references it with `type.kind: ResourceType`.

**Crossplane-backed type** — emit a `XPostgreSQLInstance` / vendor claim instead of an in-cluster StatefulSet. Outputs source from `${applied.claim.status.connectionDetails.*}`. `readyWhen` keys off `applied.claim.status.conditions[type=Ready].status == 'True'`. Provisioner setup is install-side; the ResourceType only owns the claim shape + output mapping.

**Optional admin UI** — gate an `HTTPRoute` and admin Deployment with `includeWhen: "${environmentConfigs.adminEnabled && has(gateway.ingress.external)}"` so dev bindings light it up and prod bindings keep it off. The shipped `postgres` / `valkey` / `nats` defaults use this pattern.

## Gotchas

- **`spec.parameters` is immutable on a Resource.** PE edits to `parameters.openAPIV3Schema` don't break existing Resources (extra fields tolerated), but removing a required field or tightening a regex can break Resources that haven't been re-applied. Same evolution rule as ComponentType — additive changes are safe, removals are not.
- **Outputs must use a ref kind for credentials.** `value:` outputs resolve on the control plane and persist on `ResourceReleaseBinding.status.outputs[].value` — anyone with binding read access sees the literal. Use `secretKeyRef` / `configMapKeyRef` for any sensitive material.
- **ESO `refreshInterval: "0"` on Password-generator-backed Secrets.** The `Password` generator is stateless; every call returns a new random value. Non-zero refresh rotates the password and desyncs running consumers whose env vars resolved at pod-start. The shipped defaults all use `"0"` for this reason — keep it.
- **`applied.<id>.*` is not in scope for `template` or `includeWhen`** — only for `readyWhen` and `outputs`. The webhook rejects template / includeWhen references to `applied.*`.
- **`metadata.namespace` substitution.** Don't hardcode literal namespaces in templates. Use `${metadata.namespace}` (the binding's project-env namespace). The webhook rejects literal namespace strings.
- **`outputs[].name` is the public contract** with consumers. Renaming an output is a breaking change — consuming Workloads' `envBindings: { <old-name>: ENV_VAR }` will surface `OutputNotResolved` on the consumer's `ReleaseBinding`. Version the type instead.
- **`retainPolicy: Retain` on the type doesn't auto-protect production.** It's the *default* — per-env bindings can override (and dev bindings usually should override to `Delete` so cleanup works). PEs leave the type at `Delete` and prod bindings opt into `Retain`.
- **The shipped `postgres` / `valkey` / `nats` defaults are not production-grade.** They use in-cluster StatefulSets with single replicas. Reference the pattern (ESO + Password generator + `readyWhen` + admin UI gate); replace the actual provisioner with a managed claim for production.
- **No webhook-side schema validation on `ResourceReleaseBinding.spec.resourceTypeEnvironmentConfigs`.** Invalid env-config data surfaces at render time as `Synced=False, Reason=RenderingFailed`. Same precedent as ComponentType's `componentTypeEnvironmentConfigs`.

## Related

- [`../concepts.md`](../concepts.md) *Cluster vs namespace scope*, *Immutability and update semantics*
- [`../cel.md`](../cel.md) — CEL surface for `template` / `includeWhen` / `readyWhen` / `outputs`
- [`author-componenttype.md`](./author-componenttype.md) — parallel pattern for component templates (schema, CEL, allow-lists)
- [`../authoring.md`](../authoring.md) *Cluster ↔ namespace scope*, *Repo paths*, *Git workflow*
