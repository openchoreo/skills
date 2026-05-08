# Manage secrets

Create a `SecretReference` that pulls a secret from the platform's external secret store (ESO-backed: Vault, AWS Secrets Manager, OpenBao, …) and consume it in a Workload — as an env var, as a mounted file, or as Git auth for a source build.

## When to use

- The Workload needs a credential (DB password, API key, token, TLS cert, vendor secret) that should not live in Git
- Pulling from a private Git repo (use `kubernetes.io/basic-auth` or `kubernetes.io/ssh-auth`) — see `recipes/build-from-source.md`
- Pulling from a private container registry (use `kubernetes.io/dockerconfigjson`) — usually a PE-side ClusterComponentType concern; see `recipes/deploy-prebuilt-image.md`

## Prerequisites

A `ClusterSecretStore` exists in the workflow plane and points at the external backend. **This is PE-owned** — if `list_secret_references` returns the resources you expect to see but they're stuck in error, or if the store doesn't exist at all, escalate to `openchoreo-platform-engineer`.

To check what's available now:

```yaml
list_secret_references
  namespace_name: default
```

## Recipe — create a SecretReference

### 1. Compose the spec

The `template.type` field controls how the resulting Kubernetes Secret is shaped:

| `template.type` | Use case |
|---|---|
| `Opaque` (default) | generic key-value secrets (DB passwords, API keys) |
| `kubernetes.io/basic-auth` | username + password (private Git via HTTPS) |
| `kubernetes.io/ssh-auth` | SSH key (private Git via SSH) |
| `kubernetes.io/dockerconfigjson` | container registry auth |
| `kubernetes.io/dockercfg` | legacy registry auth |
| `kubernetes.io/tls` | TLS cert + key |
| `bootstrap.kubernetes.io/token` | bootstrap token |

`data[]` shape:

```yaml
data:
  - secretKey: <key in the resulting K8s Secret>
    remoteRef:
      key: <path/identifier in the external secret store>
      property: <optional — specific field inside the remote secret>
      version: <optional — provider-specific version reference>
```

Each entry maps one field in the remote secret to one key in the local Secret.

`refreshInterval` defaults to `1h` — how often the controller resyncs from the backend. Lower for faster rotation; higher for less load.

### 2. Apply via MCP

Create:

```yaml
create_secret_reference
  namespace_name: default
  name: db-secret
  spec:
    refreshInterval: 1h
    template:
      type: Opaque
    data:
      - secretKey: password
        remoteRef:
          key: db/credentials
          property: password
```

Update an existing reference (full-spec replacement — read first, modify, write back):

```yaml
get_secret_reference
  namespace_name: default
  name: db-secret
# ...edit the returned spec locally...
update_secret_reference
  namespace_name: default
  name: db-secret
  spec: <full updated spec>
```

Delete (destructive — Workloads referencing this `secretKeyRef.name` will start failing on next reconcile; confirm with the user):

```yaml
delete_secret_reference
  namespace_name: default
  name: db-secret
```

### 3. Verify it synced

```yaml
get_secret_reference
  namespace_name: default
  name: db-secret
```

Check `status.conditions[]` and `status.lastRefreshTime`. If it's not synced, the cause is usually a wrong `remoteRef.key` / `property` or the ClusterSecretStore being misconfigured (PE side).

## Recipe — consume a secret in a Workload

Once the SecretReference exists, reference it from the Workload's `container.env[]` or `container.files[]` via `update_workload`.

### Env var from a secret

```yaml
container:
  env:
    - key: DB_PASSWORD
      valueFrom:
        secretKeyRef:
          name: db-secret              # SecretReference metadata.name
          key: password                # secretKey from data[]
```

### Mounted file from a secret

```yaml
container:
  files:
    - key: tls.crt
      mountPath: /etc/tls
      valueFrom:
        secretKeyRef:
          name: tls-cert
          key: certificate
```

The full update flow (read → modify → update_workload) is in `recipes/configure-workload.md`.

## Patterns

### Generic Opaque secret (most common)

```yaml
apiVersion: openchoreo.dev/v1alpha1
kind: SecretReference
metadata:
  name: db-secret
  namespace: default
spec:
  refreshInterval: 1h
  template:
    type: Opaque
  data:
    - secretKey: password
      remoteRef:
        key: db/credentials
        property: password
```

Consume:

```yaml
env:
  - key: DB_PASSWORD
    valueFrom:
      secretKeyRef:
        name: db-secret
        key: password
```

### Basic-auth secret (private Git)

```yaml
spec:
  template:
    type: kubernetes.io/basic-auth
  data:
    - secretKey: username
      remoteRef: {key: secret/git/github-token, property: username}
    - secretKey: password
      remoteRef: {key: secret/git/github-token, property: token}
```

Consumed by a Component's `spec.workflow.parameters.repository.secretRef: <name>`. See `recipes/build-from-source.md`.

### TLS cert + key

```yaml
spec:
  template:
    type: kubernetes.io/tls
  data:
    - secretKey: tls.crt
      remoteRef: {key: certs/api, property: cert}
    - secretKey: tls.key
      remoteRef: {key: certs/api, property: key}
```

## Gotchas

- **`remoteRef.key` is the path in the external store, not the Kubernetes name.** Different backends format the path differently (Vault: `secret/data/foo`, AWS: ARN, OpenBao: `secret/foo`). Match what the PE configured.
- **`remoteRef.property` is optional but usually needed.** Without it, the entire remote secret is fetched into one field. Most secrets have multiple fields; pick the one you want via `property`.
- **`template.type` matters for downstream consumers.** Private Git wants `basic-auth` or `ssh-auth`; private registry wants `dockerconfigjson`. Generic env-var consumption works with `Opaque`.
- **`refreshInterval: 1h` is the default.** If the upstream secret rotates more often than that, lower this — but each refresh hits the backend, so don't drop below `5m` without reason.
- **`secretKeyRef.name` in env/files is the SecretReference's `metadata.name`**, not the underlying K8s Secret name. The controller manages the K8s Secret behind the scenes.
- **ClusterSecretStore is a PE prereq.** ESO must be installed in the cluster, and a ClusterSecretStore configured to point at the backend. If the SecretReference status shows a backend-side error, escalate.
- **Secrets do not auto-sync into the runtime container.** A rotated secret in the backend updates the K8s Secret on the next `refreshInterval`, but the running pod sees the old value until it restarts (env vars) or the kubelet projects the new value (mounted files take effect within a short delay). Restart the workload to force env-var refresh.

## Related recipes

- [`configure-workload.md`](configure-workload.md) — env vars + files in the Workload spec
- [`build-from-source.md`](build-from-source.md) — `repository.secretRef` for private Git
- [`deploy-prebuilt-image.md`](deploy-prebuilt-image.md) — private registry image pull (PE-side ClusterComponentType concern)
- [`override-per-environment.md`](override-per-environment.md) — different secret references per environment via `workloadOverrides`
