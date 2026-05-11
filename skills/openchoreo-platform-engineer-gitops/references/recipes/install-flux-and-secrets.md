# Recipe — Install Flux CD + git-token / gitops-token secrets

Install Flux into the cluster when scaffolding finds it missing, and provision the `git-token` / `gitops-token` secrets the build-and-release workflows read from the `ClusterSecretStore`.

The agent **does** the install (with explicit user confirmation) — don't tell the user to "follow the Flux docs". Authoritative install reference: <https://fluxcd.io/flux/installation/>.

## Preconditions

- `occ` configured + active context confirmed with the user. The wrong context installs Flux into the wrong cluster.
- `kubectl` configured against the same cluster as `occ`. Verify with `kubectl config current-context` and `kubectl cluster-info`.
- The cluster's `ClusterSecretStore` provider is reachable from outside the cluster (so the agent can write the keys upstream).

## 1. Install Flux

### 1a. Check what's already there

```bash
kubectl get pods -n flux-system 2>/dev/null      # any Flux pods?
kubectl get crd | grep fluxcd.io                 # CRDs installed?
command -v flux                                  # CLI available locally?
```

If the namespace is empty and there are no CRDs, no Flux is running. Install it.

### 1b. Pick an install method

| Method | When |
| --- | --- |
| `flux install` (CLI) | Local cluster (k3d / kind / minikube), quick start |
| `kubectl apply -f` (manifests) | Pinned version, scripted install |
| `flux bootstrap <provider>` | Production setup with self-managed Flux config in a Git repo |

For most scaffolding workflows, `flux install` or `kubectl apply -f` is the right starting point. **Ask the user before running** — this is cluster-altering.

```bash
# CLI install
flux install

# Or manifest install (pin a specific version):
kubectl apply -f https://github.com/fluxcd/flux2/releases/latest/download/install.yaml
```

`flux bootstrap` is heavier — it puts Flux's own config under Git management. Use only when the user explicitly asks for it.

### 1c. Verify

```bash
flux check                                       # health check
kubectl get pods -n flux-system                  # source-controller, kustomize-controller, ... all Running
```

## 2. Configure git auth (private repos)

If the scaffolded repo is private, pre-create a Secret in `flux-system` for Flux's `GitRepository` to read with:

```bash
# Username + token (HTTPS)
flux create secret git git-credentials \
  --url=<remote-url> \
  --username=<git-username> \
  --password=<personal-access-token> \
  -n flux-system

# Or SSH
flux create secret git git-credentials \
  --url=ssh://git@github.com/<org>/<repo> \
  --ssh-key-algorithm=rsa --ssh-rsa-bits=4096 \
  -n flux-system
```

Reference: <https://fluxcd.io/flux/components/source/gitrepositories/#secret-reference>.

Then uncomment `spec.secretRef` in `flux/gitrepository.yaml`:

```yaml
spec:
  secretRef:
    name: git-credentials
```

For public repos, skip §2 entirely.

## 3. git-token / gitops-token secrets (build-and-release workflows)

The build-and-release Workflow CRs (installed via [`install-defaults.md`](./install-defaults.md)) read two keys from a `ClusterSecretStore` on the workflow plane:

- `git-token` — used to clone source repos (needed for private source repos)
- `gitops-token` — used to push branches and open PRs in the GitOps repo

Provisioning steps depend on the secret backend behind the `ClusterSecretStore`. The agent should know the backend in use; if not, ask the user.

### 3a. Verify the store exists

```bash
kubectl get clustersecretstore
```

If empty, the operator hasn't wired the secret store yet — escalate. The agent doesn't install / configure External Secrets Operator (ESO) or the upstream backend; it just consumes from a ready store.

### 3b. Provision the keys upstream

**OpenBao (k3d-local default):**

```bash
kubectl exec -n openbao openbao-0 -- bao kv put secret/git-token   git-token=<user-supplied PAT>
kubectl exec -n openbao openbao-0 -- bao kv put secret/gitops-token git-token=<user-supplied PAT>
```

Both store the PAT under the field name `git-token` — that's what the Workflow CRs' `ExternalSecret`s read.

**HashiCorp Vault:**

```bash
vault kv put secret/git-token   git-token=<PAT>
vault kv put secret/gitops-token git-token=<PAT>
```

**AWS Secrets Manager:**

```bash
aws secretsmanager create-secret --name git-token \
  --secret-string '{"git-token":"<PAT>"}'
aws secretsmanager create-secret --name gitops-token \
  --secret-string '{"git-token":"<PAT>"}'
```

Other backends: use the provider's tooling. The shape is consistent — `<key-name>` (`git-token` / `gitops-token`) with a field named `git-token` carrying the PAT.

### 3c. Confirm ESO sync

The `ExternalSecret`s defined in the Workflow CRs are per-run (created in the workflow-plane namespace per `WorkflowRun`). They won't exist until a build runs, but the upstream secrets must exist before that. To verify the store can resolve:

```bash
kubectl get externalsecret -A                    # any existing ExternalSecrets healthy?
```

## 4. Ask the user for the PAT

The agent doesn't generate or hold the user's PAT. Ask the user to:

1. Generate a PAT with `repo` scope (GitHub) or equivalent.
2. Paste it into the agent — the agent uses it for the upstream secret-write commands but **does not commit it to Git**.

For repos under heavy automation, two separate PATs (one read-only for source, one read/write for GitOps) is the more secure pattern.

## Gotchas

- **`flux install` is cluster-altering.** Always confirm with the user before running.
- **`flux bootstrap` is even heavier** — it creates a sibling Git repo (or commits to one) for Flux's own config. Don't use it unless the user asked for `bootstrap`.
- **Public repos don't need `git-credentials`.** Skip §2 if the repo is public; uncommenting `secretRef` with no secret in place will fail.
- **`git-token` and `gitops-token` are workflow-plane concerns.** They're separate from `git-credentials` (which is Flux-controller-side). All three may need to exist on the same cluster.
- **PATs leak via shell history.** Use `read -s` or paste into a `kubectl exec -i` interactive session if the cluster supports it. Never commit a PAT to Git.

## Related

- Flux install docs — <https://fluxcd.io/flux/installation/>
- [`install-defaults.md`](./install-defaults.md) — installs the Workflow CRs that consume `git-token` / `gitops-token`
- [`scaffold.md`](./scaffold.md) — calls this recipe when Flux is missing
