# Recipe — Author a SecretReference via Git

A `SecretReference` points at a key in an external secret store (Vault, AWS Secrets Manager, OpenBao, …). External Secrets Operator (ESO) syncs it into a K8s `Secret` on the DataPlane, where Workloads consume it via `valueFrom.secretKeyRef`.

**Never commit a raw `Secret` CR.** That defeats the GitOps + external-secret-store invariant. The plaintext lives in the external store; only the *reference* lives in Git.

Per `gitops/overview.md` *Secrets Management*, `SecretReference` is a platform-team responsibility — authoring lives here. **Consumption** (referencing a secret from a Workload's env / files) is a developer concern and out of scope for this skill.

## Preconditions

- A `ClusterSecretStore` (or namespace-scoped `SecretStore`) is configured and resolves against the external backend. Verify with `kubectl get clustersecretstore` (or `kubectl get secretstore -n <ns>`). The store's lifecycle is operator-side, not this skill.
- The desired keys exist in the external store. The skill can't put secrets there; the operator / human does that out-of-band.

## Steps

### 1. Source the shape

```text
https://openchoreo.dev/docs/reference/api/platform/secretreference.md
```

Or template:

```bash
occ secretreference get db-credentials -n default > /tmp/sr.yaml
```

### 2. Compose the spec

```yaml
# shape: https://openchoreo.dev/docs/reference/api/platform/secretreference.md (occ v1.0.x)
apiVersion: openchoreo.dev/v1alpha1
kind: SecretReference
metadata:
  name: db-credentials
  namespace: default
spec:
  template:
    type: Opaque
  data:
    - secretKey: DB_PASSWORD
      remoteRef:
        key: prod/db-credentials
        property: password
    - secretKey: DB_USERNAME
      remoteRef:
        key: prod/db-credentials
        property: username
  refreshInterval: 1h
  targetPlane:
    name: default
    kind: ClusterDataPlane
```

Key fields:

- **`spec.template.type`** — usually `Opaque`. Other K8s secret types (`kubernetes.io/tls`, `kubernetes.io/dockerconfigjson`) work when the upstream store provides the right shape.
- **`spec.data[]`** — one entry per consumed key. `secretKey` is what the Workload references via `valueFrom.secretKeyRef.key`. `remoteRef.key` is the path in the external store; `remoteRef.property` is an optional sub-key (e.g. for JSON-shaped secrets).
- **`spec.refreshInterval`** — how often ESO refreshes from upstream. `1h` is common; `15s` is what the workflow-plane git-tokens use because builds need them fresh.
- **`spec.targetPlane`** — which DataPlane this secret should land on. Defaults vary; set explicitly for multi-plane setups.

### 3. Save and commit

```bash
git checkout -b platform/secretref-<name>-$(date +%Y%m%d-%H%M%S)
git add namespaces/<ns>/platform/secret-references/<name>.yaml
git commit -s -m "platform: add SecretReference <name>"
git push origin HEAD
gh pr create --fill
```

### 4. Verify after merge

```bash
flux get kustomizations -A
occ secretreference get <name> -n <ns>     # Ready=True
# On the data plane, the synced Secret:
kubectl get secret <name> -n <ns> -o yaml  # should exist; data values stay encoded
```

## Consumption from a Workload

(Application side — out of scope for authoring; included here as cross-reference for the consumer shape.)

```yaml
# Workload.spec.container.env / files
env:
  - key: DB_PASSWORD
    valueFrom:
      secretKeyRef:
        name: db-credentials
        key: DB_PASSWORD
files:
  - key: /etc/db.json
    mountPath: /etc/db.json
    valueFrom:
      secretKeyRef:
        name: db-credentials
        key: DB_JSON
```

The `secretKeyRef.name` is the `SecretReference`'s `metadata.name`. `secretKeyRef.key` is one of the `spec.data[].secretKey` values.

## Variants

### `ClusterSecretStore` not yet wired

Then there's no place to point `SecretReference` at. Two options:

- Configure the `ClusterSecretStore` (operator-side; this skill doesn't do it but can guide). The ESO docs at <https://external-secrets.io/> are the reference.
- Use a different secret-delivery mechanism (e.g. K8s `Secret`s applied out of band, with `valueFrom.secretKeyRef` pointing at that name). Not recommended — defeats GitOps.

### Namespace-scoped `SecretStore`

If the store is namespace-scoped instead of cluster-scoped, the `SecretReference` controller picks the right kind from the cluster — the SecretReference itself doesn't carry the store name (it's resolved by the data plane's secret-store binding). Verify by checking the rendered `ExternalSecret` on the data plane:

```bash
kubectl get externalsecret -n <runtime-ns> <name> -o yaml
```

The `spec.secretStoreRef.kind` field there shows what got picked.

## Gotchas

- **Don't commit raw K8s `Secret` resources.** Even encoded, they're a leak surface and break the "Git has no plaintext" invariant.
- **`remoteRef.key` is provider-specific.** Vault uses `secret/data/<path>`; AWS Secrets Manager uses ARN-shaped names; OpenBao matches Vault. Confirm the format with whoever set up the store.
- **`refreshInterval` is a tradeoff.** Too short → constant churn on the data plane Secret + ESO API quota burn. Too long → secret rotations don't propagate. `1h` is the common default; `15s` is for short-lived tokens (e.g. workflow-run git-tokens).
- **The external store keys must already exist** before the SecretReference reconciles. ESO surfaces a `Failed` condition on the data plane's `ExternalSecret` when the key is missing — check `kubectl describe externalsecret <name> -n <runtime-ns>` for the error.
- **Secrets and DataPlanes.** A `SecretReference` lands a Secret on its target DataPlane only. Multi-plane setups need one SecretReference per plane (or a setup that fans out — operator concern).

## Related

- `gitops/overview.md` *Secrets Management* — upstream doc
- ESO docs — <https://external-secrets.io/>
- `secret-management.mdx` — `https://openchoreo.dev/docs/platform-engineer-guide/secret-management.md`
- Developer-side consumption is out of scope here — the consumer references `valueFrom.secretKeyRef.name: <SecretReference.metadata.name>` in their Workload's `env[]` or `files[]`.
