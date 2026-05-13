# Recipe — Scaffold a GitOps repo

Single recipe for all scaffolding paths: pristine cluster, platform-only cluster (CCTs / Traits / Workflows present but no projects), or active cluster (running projects / components). The flow detects which case applies, runs an inventory, asks the user **per resource category** what to do, then stamps the tree, executes the chosen capture / replace actions, and wires Flux.

For ongoing platform-resource authoring (after scaffolding), see the `author-*.md` recipes.

## 1. Preconditions — confirm cluster context

```bash
occ config context list                         # active occ context (URL, namespace)
kubectl config current-context && kubectl cluster-info | head -2
```

**Ask the user — always.** Scaffolding into the wrong cluster's resources is catastrophic; the verification can't be done programmatically (occ talks to a control-plane URL; kubectl could be pointing at the control plane, a data plane, or an unrelated cluster). Surface both contexts side by side and ask:

> Active `occ` context `<name>` (control plane `<url>`, namespace `<ns>`) and `kubectl` context `<name>` (cluster `<api-url>`). Scaffolding GitOps for this cluster — right?

Don't proceed past §1 until confirmed. If the user says "no", stop and ask which contexts they want active.

Detect k3d:

```bash
kubectl cluster-info | grep -qE 'k3d|host\.k3d\.internal' && echo "k3d detected"
```

Record the result; it drives registry-URL substitution later (§6).

Note: the inventory in §2 surfaces any `ClusterSecretStore` / `SecretStore` already present — pass the backend type (OpenBao / Vault / AWS SM / GCP SM / `external-secrets` operator) to [`install-flux-and-secrets.md`](./install-flux-and-secrets.md) §4 so the right backend section is used when provisioning `git-token` / `gitops-token`.

Check Flux:

```bash
command -v flux                                 # local CLI
kubectl get pods -n flux-system 2>/dev/null     # cluster-side
kubectl get gitrepository,kustomization -A 2>/dev/null   # existing GitOps?
```

- `flux` CLI missing → install it (`brew install fluxcd/tap/flux`, or `curl -s https://fluxcd.io/install.sh | sudo bash`). Ask user before running.
- Cluster has no Flux → defer to [`install-flux-and-secrets.md`](./install-flux-and-secrets.md) at §8.
- `kubectl get gitrepository -A` returns resources → **stop**. The cluster is already under GitOps. Confirm with the user before continuing.

## 2. Inventory the cluster

Always run, even for "pristine" — the user might have things they forgot about.

```bash
# Cluster-scoped
occ clustercomponenttype list
occ clustertrait list
occ clusterworkflow list
occ clusterdataplane list
occ clusterworkflowplane list
occ clusterobservabilityplane list
occ clusterauthzrole list
occ clusterauthzrolebinding list
kubectl get clustersecretstore 2>/dev/null     # external-secrets backend (OpenBao / Vault / AWS SM / GCP SM)

# Per-namespace (loop over namespaces labelled openchoreo.dev/control-plane=true)
occ namespace list
# For each NS:
occ environment list -n "$NS"
occ deploymentpipeline list -n "$NS"
occ componenttype list -n "$NS"
occ trait list -n "$NS"
occ workflow list -n "$NS"
occ secretreference list -n "$NS"
kubectl get secretstore -n "$NS" 2>/dev/null
occ authzrole list -n "$NS"
occ authzrolebinding list -n "$NS"
occ observabilityalertrule list -n "$NS" 2>/dev/null
occ project list -n "$NS"
# For each project: occ component list -n "$NS" -p "$PROJECT"
```

Classify:

| Class | Signal |
| --- | --- |
| **Pristine** | No platform resources, no projects |
| **Platform-only** | CCTs / Traits / Workflows / Environments / Pipeline exist, but no projects/components |
| **Active** | At least one project + component running |
| **Already on GitOps** | `kubectl get gitrepository -A` returns resources — stop (per §1) |

Show the user the summary grouped by category before §3.

> **CI workflow gotcha.** If the inventory finds `dockerfile-builder` / `paketo-buildpacks-builder` / `gcp-buildpacks-builder` / `ballerina-buildpack-builder` (the vanilla CI workflows), flag them explicitly. These build and write the `Workload` CR directly to the cluster — Flux would revert it. Surface a recommendation to **Replace** them with the GitOps versions when the workflow category comes up in §4. See [`../authoring.md`](../authoring.md) *Vanilla CI workflows aren't GitOps-compatible*.

## 3. Ask the user upfront

Scaffolding is a wizard, not a stream of ad-hoc prompts. Ask **all** of these before §5 (directory stamping), so the user makes their decisions once and you execute uninterrupted afterwards.

### Critical question — ask, don't default

**Repo visibility** — public or private? Private repos need a `git-credentials` Secret in `flux-system` for the Flux `GitRepository.spec.secretRef`. No safe default.

### Defaults — surface, let the user redirect if they care

| Decision | Default |
| --- | --- |
| Repo pattern | Mono-repo. Only deviate if the user mentioned multi-repo / per-project. Non-mono layouts need a `release-config.yaml` at the repo root — schema in [`../../assets/release-config.yaml.example`](../../assets/release-config.yaml.example). |
| First namespace | If the cluster has exactly one OpenChoreo-labeled namespace, use it. Otherwise `default`. Ask only if `occ namespace list` returns multiple OpenChoreo namespaces. |
| Branch | `main`. |
| Workflow scope when scaffolding defaults | `ClusterWorkflow` (cluster-scoped). |
| Git host | Autodetect from `git remote -v` and `command -v gh / glab / bb`. No question. |

After these answers come back, also ask **per-category Capture / Replace / Skip** (§4) — that one needs the §2 inventory first, so it's naturally the next prompt.

The remaining steps (§5–§10) just execute the user's choices. Brief context-ack at destructive moments (`gh repo create --push`, `flux install`, `kubectl apply -f flux/`) — not new questions.

## 4. Per-category decisions

**Don't drown the user in per-category questions.** Pick the right batching by §2 class, present a single summary with the recommendation per category, and only drop into per-category prompts if the user wants to override the suggestion.

**The four options (apply per category):**

| Choice | What happens |
| --- | --- |
| **Capture** | `occ get`, strip `status:` / `metadata.managedFields:` / `metadata.creationTimestamp:` / `metadata.resourceVersion:` / `metadata.uid:`, save under the canonical path from [`../authoring.md`](../authoring.md) *Repo paths*. Flux takes ownership on the next reconcile. |
| **Skip — keep on cluster** | Don't touch. Stays unmanaged on the cluster; Flux won't reconcile or prune. |
| **Skip — delete from cluster** | Destructive. `kubectl delete` after explicit per-resource confirmation. Use when the resource shouldn't exist anywhere. |
| **Replace with defaults** | Only for categories with documented defaults (Project / Environments / Pipeline / CCTs / Traits / Workflows). Scaffold from upstream (see §6); after Flux reconciles cleanly, optionally `kubectl delete` the cluster-side originals. |

Categories without defaults (`SecretReference`, `AuthzRole`, `ObservabilityAlertRule`, `NotificationChannel`) get the first three options only.

**Suggested batching by class — minimise prompts:**

| Class | Pattern |
| --- | --- |
| **Pristine** | One prompt: "Scaffold all defaults? `[Yes / Pick categories]`". `Yes` → Replace-with-defaults for every category with defaults; skip-keep for everything else. `Pick categories` falls back to per-category. |
| **Platform-only** | One summary table showing the recommendation per category (Capture for customized, Replace for at-defaults, **Replace** for vanilla CI workflows — mandatory per §2 gotcha). Single prompt: "Apply all recommendations? `[Yes / Adjust]`". `Adjust` → per-category. |
| **Active** | Two prompts: (a) "Capture all running projects/components/workloads/releases/bindings into Git? `[Yes / Pick / Skip apps]`" and (b) the same summary-and-confirm pattern as Platform-only for the platform layer. |

Apply the per-category options spelled out in the recipe text only when the user wants to override the batch recommendation — not as the default flow.

> **Application resources** (`Project` / `Component` / `Workload` / `ComponentRelease` / `ReleaseBinding`) are application-side and technically out of scope for this skill. Two paths: (a) capture verbatim into the GitOps repo here as a one-off — flag in the commit message that they're for follow-up application-side review, or (b) skip and have someone bring them across project-by-project later.

## 5. Stamp the directory tree

```bash
NS="<first-namespace from §3>"

mkdir -p platform-shared/{component-types,traits,workflows}
mkdir -p platform-shared/authz/{roles,role-bindings}
mkdir -p platform-shared/cluster-workflow-templates/argo
mkdir -p "namespaces/$NS/platform/{component-types,traits,workflows,secret-references}"
mkdir -p "namespaces/$NS/platform/infra/{deployment-pipelines,environments}"
mkdir -p "namespaces/$NS/platform/authz/{roles,role-bindings}"
mkdir -p "namespaces/$NS/platform/observability/{alert-rules,notification-channels}"
mkdir -p "namespaces/$NS/projects"
mkdir -p flux

cat > "namespaces/$NS/namespace.yaml" <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: $NS
  labels:
    openchoreo.dev/control-plane: "true"
EOF
```

> The `openchoreo.dev/control-plane=true` label is required — the controller filters discovery by it.

Add CODEOWNERS. Read [`../../assets/codeowners-platform-shared`](../../assets/codeowners-platform-shared) and write it to `.github/CODEOWNERS` in the scaffolded repo, then edit the placeholder team handle.

## 6. Execute per-category actions

For each category from §4:

### Capture path

```bash
occ <kind> get <name> [-n <ns>] > /tmp/capture.yaml
# Strip status: and metadata fields:
yq -i 'del(.status, .metadata.managedFields, .metadata.creationTimestamp, .metadata.resourceVersion, .metadata.uid)' /tmp/capture.yaml
# Move into place per repo paths
mv /tmp/capture.yaml <canonical-path>
```

If `yq` isn't available, do the strip manually. Result must not contain `status:`, `metadata.managedFields:`, or the auto-generated identity fields.

### Replace-with-defaults path

Fetch each resource from upstream via WebFetch, then place it under the canonical repo path.

For the **vanilla defaults** (Project / Environments / Pipeline / 4 CCTs / 1 ClusterTrait), fetch from `https://raw.githubusercontent.com/openchoreo/openchoreo/main/samples/getting-started/<path>` per the inventory in [`../authoring.md`](../authoring.md) *Vanilla defaults*.

For the **GitOps Workflow CRs + Argo ClusterWorkflowTemplates**, fetch from `https://raw.githubusercontent.com/openchoreo/sample-gitops/main/<path>` per [`../authoring.md`](../authoring.md) *GitOps resources*.

For the **extra shapes** (`database`, `message-broker`, `persistent-volume`, `api-management`) if the user asks for them, fetch from the same `sample-gitops` URLs per [`../authoring.md`](../authoring.md) *Extra shapes*.

**Three required transforms** when materializing each file:

1. **Scope swap.** If §3 chose cluster-scoped workflows / CCTs / Traits but the source is namespace-scoped (or vice versa), apply the conversion in [`../authoring.md`](../authoring.md) *Cluster ↔ namespace scope*. Update the referrer `allowedWorkflows[].kind` / `allowedTraits[].kind` on every ComponentType you scaffold.
2. **`allowedWorkflows[]` rewrite.** The vanilla `ClusterComponentType` files list the vanilla CI workflows (`dockerfile-builder` etc.). Swap them for the GitOps Workflow names (`docker-gitops-release` etc.) with the chosen `kind:`.
3. **Hard-coded values in the GitOps Workflow `runTemplate`.** Edit `gitops-repo-url` (the remote URL of *this* scaffolded repo), `gitops-branch` (the branch from §3), `registry-url` (k3d-local default if §1 detected k3d, otherwise ask the user), and `image-name` / `image-tag` (usually leave the defaults).

For the install procedure end-to-end, defer to [`install-defaults.md`](./install-defaults.md).

### Skip — delete path

```bash
kubectl delete <kind> <name> [-n <ns>]      # confirm per resource
```

### Skip — keep path

No action. Resource stays unmanaged on the cluster.

## 7. CODEOWNERS + initial commit

```bash
git init -b "<branch from §3>"
git add -A
git status                                    # show before committing
git commit -s -m "Initial OpenChoreo GitOps repo scaffold"
```

> **Don't push yet.** Remote wiring is the next explicit step.

## 8. Wire the remote

Visibility is already decided in §3. Confirm the exact remote URL before running — surface it and proceed once acknowledged:

> About to create `gh repo create <org>/<name> --<visibility> --source=. --remote=origin --push`. This pushes immediately. Proceed?

```bash
git remote -v                                 # any existing remote already?
```

If a remote already exists, confirm with the user that it's the right one — don't overwrite it. Otherwise:

```bash
gh repo create <org>/<name> --<visibility> --source=. --remote=origin --push    # <visibility> from §3
```

For GitLab / Bitbucket, use `glab repo create` / `bb repo create`. For self-hosted, the user creates the empty repo first, then `git remote add origin <url>` + `git push -u origin <branch>`.

## 9. Install Flux (if needed) + provision secrets

- **Flux already installed** (per §1 check) → skip the install. No ask.
- **Flux missing** → install per [`install-flux-and-secrets.md`](./install-flux-and-secrets.md) §1. **Ask the user before running** `flux install` / `kubectl apply -f` — it's cluster-altering. Surface the active `kubectl` context (re-confirm from §1) along with the install command.

For the build workflows that were brought in via `Replace with defaults`:

- **`ClusterSecretStore` present** (per §2 inventory, surfaced backend type) → resolve `git-token` / `gitops-token` against it. Don't ask "should I set up a secret store?". Use the backend that's there. Only ask the user for the token *source* (gh CLI / manual PAT / manual secret) per `install-flux-and-secrets.md` §4.
- **No `ClusterSecretStore`** → flag this honestly and ask how to proceed (set one up out of band, or skip the build workflows for now).

If the repo is **private** (§3), pre-create `git-credentials` in `flux-system` so the Flux `GitRepository` can pull — covered in `install-flux-and-secrets.md` §2.

## 10. Wire Flux

**Ask the user before `kubectl apply -f flux/`.** Surface the `kubectl` context, the remote URL, and the namespace one more time — once Flux is bootstrapped it starts reconciling immediately. No way to undo without `kubectl delete -f flux/`.

Copy the five Flux templates from [`../../assets/flux/`](../../assets/flux/) into `flux/` in the scaffolded repo:

- `gitrepository.yaml`
- `kustomization-namespaces.yaml`
- `kustomization-platform-shared.yaml`
- `kustomization-platform.yaml`
- `kustomization-projects.yaml`

Then edit:

- `gitrepository.yaml` — `spec.url` to the remote URL from §8; `spec.ref.branch` to the branch from §3; uncomment `spec.secretRef.name: git-credentials` if §3 chose private.
- `kustomization-platform.yaml` + `kustomization-projects.yaml` — replace `<namespace>` with the first namespace from §3.

Commit + push + bootstrap:

```bash
git add flux/
git commit -s -m "Wire Flux: GitRepository + Kustomization chain"
git push origin <branch>                      # only after user confirmation

kubectl apply -f flux/                        # one-time bootstrap so Flux starts pulling
```

After this, **edit Flux resources only in Git**.

> The shipped `Kustomization`s set `spec.force: true`. Server-side apply uses field manager `kustomize-controller`; on resources previously created by `kubectl apply` (active-cluster path), this lets Flux take field ownership instead of erroring on conflict. Pre-existing resources are patched in place — no delete-and-recreate.

## 11. Verify reconciliation

```bash
flux get sources git -A                       # GitRepository READY=True, post-commit revision
flux get kustomizations -A                    # all Kustomizations READY=True
```

For each captured resource, spot-check that the cluster matches Git:

```bash
occ <kind> get <name> [-n <ns>]               # no diff = reconciled cleanly
```

If a Kustomization stays `Reconciling`, give it the documented 5m or force: `flux reconcile kustomization <name> --with-source`. If it errors: `flux events --for kustomization/<name>`.

## 12. Optional cleanup — remove cluster-side originals from Replace path

For each resource the user chose to **Replace**, after §11 shows a clean reconcile:

Ask the user per-category first. Vanilla CI workflows in particular become inert once every (Cluster)ComponentType's `allowedWorkflows[]` is rewritten — leaving them is fine:

> The four vanilla CI ClusterWorkflows (`dockerfile-builder`, `paketo-buildpacks-builder`, `gcp-buildpacks-builder`, `ballerina-buildpack-builder`) are now unreachable since every ComponentType's `allowedWorkflows[]` points at the GitOps-mode variants. Delete them, or leave them on the cluster?
> - Delete now (cleaner cluster)
> - Leave them (inert; can clean up later)

If the user chooses delete:

```bash
occ clusterworkflow delete dockerfile-builder
occ clusterworkflow delete paketo-buildpacks-builder
occ clusterworkflow delete gcp-buildpacks-builder
occ clusterworkflow delete ballerina-buildpack-builder
```

Apply the same ask-then-delete pattern to any other Replaced category.

## 13. Persist the repo profile

Save the scaffolding decisions to `CLAUDE.md` / `AGENTS.md` / agent memory under `## OpenChoreo GitOps repo profile`. Schema in [`../../assets/repo-profile.template`](../../assets/repo-profile.template). Future sessions skip §3.

## Gotchas

- **`gh repo create --push` pushes immediately.** Confirm URL + visibility before running.
- **Flux apply hits the cluster.** Re-confirm the `kubectl` context right before `kubectl apply -f flux/`.
- **`openchoreo.dev/control-plane=true` namespace label is required.** Without it, controllers ignore the namespace.
- **Capture-then-delete is two stages.** Capture commits to Git → wait for Flux to reconcile (Git versions own the names) → then `kubectl delete` the originals. Doing both in one commit risks a window where Flux prunes the freshly-captured resources via `prune: true`.
- **Vanilla CI workflows aren't GitOps-compatible.** See [`../authoring.md`](../authoring.md) *Vanilla CI workflows aren't GitOps-compatible*. Always replace, never capture as-is.
- **`Environment.spec.dataPlaneRef` is immutable.** Capture the live `dataPlaneRef` exactly; don't try to change it during migration.
- **Don't capture controller-managed resources** — `ComponentRelease` is immutable but generated by `occ`; `RenderedRelease` is fully controller-managed and never authored. Capture upstream resources (Component, Workload) and let `occ componentrelease generate` produce releases from them later.
- **CODEOWNERS placeholders.** Edit the team handle; if you ship the literal `@<your-org>/platform-team`, PRs route to nowhere.
- **Multi-cluster (`clusters/<name>/`).** If §3's repo pattern picks that layout, Flux files go under `clusters/<name>/` instead of `flux/`.

## Related

- [`install-defaults.md`](./install-defaults.md) — the `Replace with defaults` paths' end-to-end procedure (Project / Envs / Pipeline / CCTs / Traits + GitOps workflows + Argo templates)
- [`install-flux-and-secrets.md`](./install-flux-and-secrets.md) — Flux install + `git-token` / `gitops-token` / `git-credentials` provisioning
- [`../authoring.md`](../authoring.md) — shape-lookup decision table, scope swap, repo paths, the CI gotcha
- [`../concepts.md`](../concepts.md) — sync ordering, immutability, verification ladder, drift recovery
- [`verify-and-recover-drift.md`](./verify-and-recover-drift.md) — what to do when Flux and the cluster diverge
