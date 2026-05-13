# Recipe — Author a SecretReference via Git

A `SecretReference` points at a key in an external secret store (Vault, AWS Secrets Manager, OpenBao). External Secrets Operator (ESO) syncs it into a K8s `Secret` on the DataPlane; Workloads consume via `valueFrom.secretKeyRef`.

**Never commit a raw `Secret` CR.** Plaintext stays in the external store; only the *reference* lives in Git.

## Preconditions

- A `ClusterSecretStore` (or namespace-scoped `SecretStore`) is configured. Verify: `kubectl get clustersecretstore` or `kubectl get secretstore -n <ns>`. Store lifecycle is operator-side.
- The keys exist in the external store (operator / human puts them there).

## Steps

### 1. Source the shape

```bash
./scripts/fetch-page.sh --exact --title "SecretReference"
```

### 2. Compose

```yaml
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

- `spec.template.type` — usually `Opaque`; other K8s types work if upstream returns the right shape.
- `spec.data[]` — one entry per consumed key. `secretKey` is what the Workload references; `remoteRef.key` is the path in the external store; `remoteRef.property` an optional sub-key (JSON-shaped secrets).
- `spec.refreshInterval` — `1h` is the common default; `15s` for short-lived tokens (e.g. workflow git-tokens).
- `spec.targetPlane` — which DataPlane the synced Secret lands on. Set explicitly for multi-plane.

### 3. Commit + verify

Branch `platform/secretref-<name>-<ts>`, message `"platform: add SecretReference <name>"`. Canonical flow in [`../authoring.md`](../authoring.md) *Git workflow*. After merge:

```bash
flux get kustomizations -A
occ secretreference get <name> -n <ns>     # Ready=True
```

The synced K8s `Secret` lands on the **target data plane** (`spec.targetPlane`), not the control plane. Verify against the data plane's kubeconfig + runtime namespace — `kubectl --kubeconfig <dataplane-kubeconfig> get secret <name> -n <runtime-ns>`. Checking the control-plane cluster will show nothing and falsely read as a sync failure.

## Consumer shape (for cross-reference)

Application-side; not authored here. The consumer references the `SecretReference` by name:

```yaml
env:
  - key: DB_PASSWORD
    valueFrom:
      secretKeyRef:
        name: db-credentials
        key: DB_PASSWORD
```

`secretKeyRef.name` = `SecretReference.metadata.name`. `secretKeyRef.key` = one of `spec.data[].secretKey`.

## Gotchas

- **Don't commit raw `Secret` CRs.** Even base64-encoded — they're a leak surface and break the "Git has no plaintext" invariant.
- **`remoteRef.key` is provider-specific.** Vault: `secret/data/<path>`. AWS SM: ARN-shaped. OpenBao: same as Vault. Confirm with whoever set up the store.
- **`refreshInterval` is a tradeoff.** Too short → churn + ESO API quota. Too long → rotations don't propagate.
- **External keys must already exist.** Missing keys surface as `Failed` on the rendered `ExternalSecret` — `kubectl describe externalsecret <name> -n <runtime-ns>`.
- **Multi-plane: one `SecretReference` per plane** (or use a fan-out setup at the operator layer).
