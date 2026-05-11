# Recipe — Scaffold a GitOps repo

Single recipe for all scaffolding paths: pristine cluster, platform-only cluster (CCTs / Traits / Workflows present but no projects), or active cluster (running projects / components). The flow detects which case applies, runs an inventory, asks the user **per resource category** what to do, then stamps the tree, executes the chosen capture / replace actions, and wires Flux.

For ongoing platform-resource authoring (after scaffolding), see the `author-*.md` recipes.

## 1. Preconditions

Per [`../../SKILL.md`](../../SKILL.md) Step 0. Run all checks, surface the active contexts to the user, get confirmation:

```bash
occ config context list                         # active occ context
kubectl config current-context && kubectl cluster-info | head -2
```

`AskUserQuestion`: "Active `occ` context = `<name>` (URL: `<…>`, namespace: `<…>`). Active `kubectl` context = `<name>` (server: `<…>`). Both pointing at the right cluster?"

Detect k3d:

```bash
kubectl cluster-info | grep -qE 'k3d|host\.k3d\.internal' && echo "k3d detected"
```

Record the result; it drives registry-URL substitution later (§6).

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

# Per-namespace (loop over namespaces labelled openchoreo.dev/control-plane=true)
occ namespace list
# For each NS:
occ environment list -n "$NS"
occ deploymentpipeline list -n "$NS"
occ componenttype list -n "$NS"
occ trait list -n "$NS"
occ workflow list -n "$NS"
occ secretreference list -n "$NS"
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

## 3. Repo-structure questions

Use `AskUserQuestion` in **two batches** (the tool caps at 4 questions per call): questions 1–4 first, then 5–6. Inventory from §2 informs the defaults — pre-select the suggested default so the user can confirm with a single click.

| # | Question | Default |
| --- | --- | --- |
| 1 | Repo pattern? | **Mono-repo** (single repo for both platform and apps). Multi-repo (platform repo + app repo) if the user explicitly asks. Anything else only on explicit ask. |
| 2 | First namespace? | If the cluster has one OpenChoreo namespace, default to that. Otherwise `default`. |
| 3 | Branch? | `main` |
| 4 | Push policy? | PR + wait-for-merge. Direct push if the user prefers. |
| 5 | Repo public or private? | (No default — ask. Private repos need `git-credentials` in `flux-system` for the Flux `GitRepository.spec.secretRef`.) |
| 6 | Workflow scope when scaffolding defaults? | **Cluster-scoped** (`ClusterWorkflow`). Switch to namespace-scoped (`Workflow`) only if asked. See [`../authoring.md`](../authoring.md) *Cluster ↔ namespace scope*. |

**Git host: autodetect, don't ask.** Run:

```bash
git remote -v                                 # already-configured remotes
command -v gh; command -v glab; command -v bb # available host CLIs
```

Pick from what's present. If the only signal is the remote URL, infer the host. Confirm with the user.

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

Add CODEOWNERS:

```bash
mkdir -p .github
cp <skill-dir>/assets/codeowners-platform-shared .github/CODEOWNERS
```

Edit the placeholder team handle.

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

```bash
git remote -v                                 # any existing remote?
```

If a remote exists, confirm it. If wrong / missing, use the autodetected host CLI:

```bash
# GitHub examples
gh repo create <org>/<name> --private --source=. --remote=origin --push    # private per §3
gh repo create <org>/<name> --public  --source=. --remote=origin --push    # public
```

> `gh repo create --push` pushes immediately. Only run after explicit user confirmation of the URL + visibility.

For GitLab / Bitbucket, use `glab repo create` / `bb repo create`. For self-hosted, the user creates the empty repo first, then `git remote add origin <url>` + `git push -u origin <branch>` after confirmation.

## 9. Install Flux (if needed) + provision secrets

If §1 found Flux missing in the cluster, or if `Replace with defaults` brought in the build-and-release workflows (which require `git-token` / `gitops-token` in a `ClusterSecretStore`), follow [`install-flux-and-secrets.md`](./install-flux-and-secrets.md).

If the repo is **private** (§3), pre-create `git-credentials` in `flux-system` so the Flux `GitRepository` can pull — also covered in `install-flux-and-secrets.md`.

## 10. Wire Flux

> **Confirm before applying `flux/`.** The active `occ` and `kubectl` contexts, the remote URL, and the first namespace are all about to become Flux-managed.

```bash
cp <skill-dir>/assets/flux/*.yaml flux/

# Edit gitrepository.yaml:
#   - spec.url: the remote URL from §8
#   - spec.ref.branch: the branch from §3
#   - if §3 was private: uncomment spec.secretRef.name: git-credentials
#
# Edit kustomization-platform.yaml + kustomization-projects.yaml:
#   - Replace <namespace> with the first namespace from §3

git add flux/
git commit -s -m "Wire Flux: GitRepository + Kustomization chain"
git push origin <branch>                      # only after user confirmation

kubectl apply -f flux/                        # one-time bootstrap so Flux starts pulling
```

After this, **edit Flux resources only in Git**.

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

```bash
# Example: vanilla CI workflows that were replaced by GitOps versions
kubectl delete clusterworkflow dockerfile-builder paketo-buildpacks-builder \
                                gcp-buildpacks-builder ballerina-buildpack-builder
```

Per-resource user confirmation. Once deleted, the originals are gone and Flux's versions own the names.

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
