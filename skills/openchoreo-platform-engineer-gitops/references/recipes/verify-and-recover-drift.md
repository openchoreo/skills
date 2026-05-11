# Recipe — Verify reconciliation and recover from drift

After any merge: walk the verification ladder. When the cluster and Git diverge: codify whichever side is correct and force reconciliation.

## Preconditions

- `occ` configured + active context confirmed with the user. Reads + drift comparisons all hit the live cluster.
- `flux` CLI installed locally — `flux get sources`, `flux get kustomizations`, `flux events`, `flux reconcile`.
- For destructive recovery (forcing reconcile against the cluster, or codifying back to Git), confirm the context once more before running.

## The verification ladder

```
GitRepository  →  Kustomization(s)  →  OpenChoreo controllers  →  RenderedRelease (apps only)
```

After a PR merges:

### 1. Flux pulled the new commit

```bash
flux get sources git -A
```

Look for the `GitRepository` named in [`../../assets/flux/gitrepository.yaml`](../../assets/flux/gitrepository.yaml). `READY=True`. `REVISION` should carry the post-merge SHA prefix.

If still on the pre-merge SHA after 1m: poll one cycle (default `interval: 1m`), then check the host for branch-protection / push failures.

### 2. The Kustomization applied

```bash
flux get kustomizations -A
```

Identify by `PATH`:

- `./platform-shared` → typically `openchoreo-platform-shared`
- `./namespaces` → `openchoreo-namespaces`
- `./namespaces/<ns>/platform` → `openchoreo-platform`
- `./namespaces/<ns>/projects` → `openchoreo-projects`

All `READY=True` and `REVISION` matching the post-merge SHA. To skip the default 5m interval:

```bash
flux reconcile kustomization <name> --with-source
```

`dependsOn` means a stuck upstream blocks downstream — fix the upstream first.

### 3. OpenChoreo controllers reconciled

For a PE-side resource (ComponentType, Trait, Workflow, Environment, …), `occ <kind> get <name>` should show what Git declares. `status.conditions[]` should be clean — no `Ready=False`.

```bash
# Examples:
occ clustercomponenttype get backend-service
occ trait get persistent-volume -n default
occ environment get production -n default
```

If `Ready=False`, the controller's message is in `status.conditions[].message`. Common causes:

- **Scope mismatch.** `ClusterComponentType` referencing a namespace-scoped `Trait` / `Workflow` in `allowedTraits` / `allowedWorkflows`. Fix the kind.
- **Required-by-default schema field missing a `default`.** Add `default:` or mark the field optional.
- **CEL context not in scope.** `${trait.instanceName}` referenced inside a ComponentType template (only available in Trait `creates[]` / `patches[]`). See [`../cel.md`](../cel.md) §5.
- **Referenced resource doesn't exist.** Environment's `dataPlaneRef` pointing at a missing plane. Wait for the plane Kustomization to apply, or fix the ref.

### 4. (Applications only — developer side) RenderedRelease

For `ReleaseBinding`s, watch the three-stage condition cascade:

- `ReleaseSynced=True` — RenderedRelease created on the target DataPlane.
- `ResourcesReady=True` — all rendered K8s resources are healthy.
- `Ready=True` — overall.

Belongs to the application side; this skill rarely touches it directly.

## When stuck

```bash
flux events --for gitrepository/<name>
flux events --for kustomization/<name>
```

`flux events` is the single most useful command when something is silently failing. Common signals:

- `dry-run failed` — manifest YAML invalid (parse error or schema mismatch). Fix and recommit.
- `dependency '<other-kustomization>' is not ready` — upstream stuck; fix that first.
- `pruning prevented` — Flux didn't prune because the resource has a finalizer. Inspect and resolve out of band, then re-reconcile.

For the OpenChoreo controller's view:

```bash
kubectl -n openchoreo-control-plane logs deployment/openchoreo-controller-manager --tail=200
```

(Namespace and deployment name depend on the install. Adjust per the active control plane.)

## Drift recovery

Drift = cluster spec ≠ Git spec for a GitOps-managed resource. Resolve by moving one side to match the other; **never `kubectl apply` against a GitOps-managed resource** — Flux will revert it on the next reconcile (it does that on purpose).

### Step 1 — Compare

```bash
git -C <repo> show HEAD:<path>            # what Git declares
occ <kind> get <name> [-n <ns>]            # what's on the cluster
diff <(git -C <repo> show HEAD:<path>) <(occ <kind> get <name> -n <ns> | grep -v '^status:' )
```

### Step 2 — Decide which is right

- **Git is right** (cluster got hand-edited; or stale from a partial apply). Force Flux to re-reconcile:
  ```bash
  flux reconcile kustomization <name> --with-source
  ```
- **Cluster is right** (out-of-band change is the intended state, but never committed). Codify back to Git:
  ```bash
  occ <kind> get <name> [-n <ns>] > /tmp/cluster.yaml
  # Strip status: and metadata.managedFields:; save to <repo>/<path>; commit, PR, merge.
  ```

### Step 3 — Document

In the PR description, link to whatever side conversation produced the change. Drift is almost always a *process* problem (someone bypassed Git); a postmortem comment is worth more than the YAML diff.

## Application-resource drift

`ComponentRelease` is immutable. If a release file in Git diverges from the cluster, **regenerate** rather than hand-editing:

```bash
occ componentrelease generate --mode file-system --root-dir <repo> --project <project> --component <component>
```

This produces a new file under `release-bindings/`'s sibling `releases/` directory. Commit it, leave the old release in place (immutable record), and update the `ReleaseBinding` to point at the new release if you intended to roll forward.

The application side owns this flow; this skill rarely runs `componentrelease generate` directly.

## Related

- [`../concepts.md`](../concepts.md) — verification ladder + drift recovery (canonical wording)
- Flux CD docs — <https://fluxcd.io/flux/cmd/flux_get_kustomizations/>, <https://fluxcd.io/flux/cmd/flux_events/>
