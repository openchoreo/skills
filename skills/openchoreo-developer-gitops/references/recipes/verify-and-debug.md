# Recipe — Verify reconciliation and debug

After a merge: walk the verification ladder. When the cluster and Git diverge or `Ready=False`: read the conditions, then the events, then the logs.

## Verification ladder

```
GitRepository  →  Kustomization(s)  →  OpenChoreo controllers  →  RenderedRelease  →  K8s objects on DataPlane
```

### 1. Flux pulled the new commit

```bash
flux get sources git -A
```

`READY=True` against the post-merge SHA. `interval: 1m` (per documented setup); poll once and continue. If still on the pre-merge SHA after >2m:

```bash
flux events --for gitrepository/<name>
```

Common causes: branch protection blocking the push, host outage, wrong `ref.branch`.

### 2. Kustomizations applied

```bash
flux get kustomizations -A
```

All `READY=True`, `REVISION` matching post-merge SHA. To skip the 5m interval:

```bash
flux reconcile kustomization <name> --with-source
```

`dependsOn` means stuck upstream blocks downstream. Identify the failing one with:

```bash
flux events --for kustomization/<name>
```

Common errors:

- `dry-run failed` — manifest YAML invalid or schema mismatch. Inspect the file, fix, recommit.
- `dependency '<other>' is not ready` — upstream Kustomization stuck. Fix that one first.
- `pruning prevented` — Flux didn't prune because the resource has a finalizer. Inspect; resolve out of band.

### 3. OpenChoreo controllers reconciled

```bash
occ component get <component> -n <ns>
occ workload get <component>-workload -n <ns>      # or whatever the workload is named
occ componentrelease get <release-name> -n <ns>
occ releasebinding get <component>-<env> -n <ns>
```

For each, `status.conditions[]` should be clean. The ReleaseBinding has three conditions to watch (in order):

| Condition          | Means                                                                                    |
| ------------------ | ---------------------------------------------------------------------------------------- |
| `ReleaseSynced`    | RenderedRelease created on the target DataPlane.                                         |
| `ResourcesReady`   | All rendered K8s resources on the DataPlane are healthy.                                 |
| `Ready`            | Overall.                                                                                 |

Pre-`Ready=True`, watch them flip in order. After `Ready=True`, the deploy is reconciled — but **not necessarily working** (see *Ready ≠ working* below).

### 4. Functional check

For public-facing services:

```bash
occ releasebinding get <component>-<env> -n <ns> -o yaml
# status.endpoints[*].serviceURL gives the URL
curl -v <url>
```

For internal services, the developer typically can't curl directly. Trigger an in-cluster path (e.g. via a frontend) or check a downstream's logs.

## When `Ready=False`

```bash
occ releasebinding get <component>-<env> -n <ns> -o yaml
# status.conditions[?(@.type=="Ready")].message — controller's reason
```

Common causes:

- **`ResourceSyncFailed`** — the RenderedRelease couldn't apply. Often a CEL eval error in the ComponentType template, or a referenced resource (Trait, Secret) missing. Cross-reference with the component-type / trait listed in the ComponentRelease.
- **`ResourcesNotReady`** — the K8s resources rendered but pods aren't healthy. Container crash, image pull failure, OOMKilled, scheduling failure.

The latter needs pod-level evidence. Drop to **`kubectl`** against the data plane directly — `kubectl get pod -n <runtime-ns> -l <selector>`, `kubectl describe pod ...`, `kubectl logs ...`. The data plane may be the same cluster as the control plane (in single-cluster installs) or a separate cluster (multi-cluster). Get the data plane's kubeconfig from your platform team or the `DataPlane` CR's documented entry point.

```bash
# If the data plane is the same cluster as the control plane:
kubectl get releasebinding <component>-<env> -n <ns> -o jsonpath='{.status.renderedReleases[0].renderedRef.name}'
# Then look up the rendered resources from that RenderedRelease name.
```

## Ready ≠ working

Two failure modes hide behind `Ready=True`:

1. **Crash-loop flapping.** A container can start, briefly report Ready, then crash. The next probe sees Ready=False, then Ready again after restart. Look at restart counts:
   ```bash
   kubectl get pod -n <runtime-ns> -l openchoreo.dev/component=<component>
   # RESTARTS > 0 over a short window is the signal
   ```

2. **Stable container, broken app.** Container is healthy from K8s's perspective but the app inside doesn't actually work — env vars bound to names the app doesn't read, dependencies pointing at the wrong service, silent connect failures. The only way to detect: **hit the actual endpoint**.

Don't claim a deploy is done because `Ready=True`. Verify with curl, with a smoke test, with a frontend interaction.

## Debugging a stuck deploy step-by-step

### Step 1 — Is the file in Git?

```bash
git -C <repo> log -- namespaces/<ns>/projects/<project>/components/<component>/
git -C <repo> show HEAD:namespaces/<ns>/projects/<project>/components/<component>/component.yaml
```

If your local commit hasn't merged yet, that's the problem.

### Step 2 — Did Flux pull it?

`flux get sources git -A` — REVISION at the merge SHA?

### Step 3 — Did the Kustomization apply it?

`flux get kustomizations -A` — `openchoreo-projects` READY=True, REVISION matches?

```bash
flux events --for kustomization/openchoreo-projects | tail -20
```

### Step 4 — What does the cluster say about the resource?

```bash
occ <kind> get <name> [-n <ns>]
# Compare to Git:
diff <(occ <kind> get <name> -n <ns>) <(git -C <repo> show HEAD:<path>)
```

A match means Flux applied; the controller hasn't yet reconciled or hit an error.

### Step 5 — Controller error

```bash
occ <kind> get <name> -o yaml | grep -A 30 conditions
# Pick the condition with status: "False" and read the message.
```

If the message points at a downstream controller (Argo Workflows for a WorkflowRun, ESO for a SecretReference), drop to that controller's logs:

```bash
kubectl logs -n <controller-ns> deployment/<controller> --tail=200
# Controller names depend on the install. Typical:
#   openchoreo-controller-manager in openchoreo-control-plane
#   eso external-secrets-controller in external-secrets
#   workflow-controller in argo
```

## Drift recovery

Drift = cluster spec ≠ Git spec for a GitOps-managed resource. **Never `kubectl apply` against a GitOps-managed resource** — Flux reverts it on the next reconcile.

```bash
# Compare:
diff <(git -C <repo> show HEAD:<path>) <(occ <kind> get <name> -n <ns> | grep -v '^status:')
```

- **Git is right** (cluster drift): `flux reconcile kustomization <name> --with-source`.
- **Cluster is right** (Git stale): `occ <kind> get <name> -n <ns> > <repo>/<path>`, strip `status:` and `metadata.managedFields:`, commit, PR.
- **`ComponentRelease` differs** — regenerate, never hand-edit:
  ```bash
  occ componentrelease generate --mode file-system --root-dir <repo> --project <project> --component <component>
  ```

## Pod-level / app-level debugging

This skill stops at "Flux applied, controllers reconciled". For deeper questions — why is my container crash-looping, what does the OOM event look like, where is my log output — drop to:

- **`kubectl`** directly against the data plane: `kubectl get pod`, `kubectl describe pod`, `kubectl logs`, `kubectl events`.
- **The observability backend** (Grafana, OpenSearch, Loki, Prometheus, Tempo) for historical logs / metrics / traces. Connection details come from the platform team or the `ObservabilityPlane` CR.

## Gotchas

- **Flux's interval is 5m for Kustomizations.** If a deploy "isn't happening", you may just be waiting. `flux reconcile --with-source` to push the next cycle.
- **`occ` reads the cluster, not Git.** When you want to know what's deployed, `occ get`. When you want to know what should be deployed, `git show`. They should agree.
- **Don't chase pod logs from a stuck Kustomization.** If `flux get kustomizations` shows the Kustomization isn't READY, no controller has touched your resource yet — pod-level evidence is irrelevant. Fix the Kustomization first.
- **Three "Ready"s in different conditions.** `Flux Kustomization Ready`, `OpenChoreo Component Ready`, `ReleaseBinding Ready` — different layers. Read the message, not just the status.

## Related

- [`../concepts.md`](../concepts.md) *Verification ladder*, *Drift recovery*
- [`onboard-component-byo.md`](./onboard-component-byo.md), [`onboard-component-source-build.md`](./onboard-component-source-build.md)
- [`promote.md`](./promote.md), [`bulk-promote.md`](./bulk-promote.md)
- `kubectl` against the data plane — for runtime / pod-level debugging
