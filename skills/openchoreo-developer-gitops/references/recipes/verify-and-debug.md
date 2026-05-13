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

The latter needs runtime evidence. Prefer **`occ component logs`** — it routes to the right data plane automatically and falls back to the observer for archived logs:

```bash
occ component logs <component> -n <ns> --env <env>           # latest pod, current env
occ component logs <component> -n <ns> --env <env> -f        # follow
occ component logs <component> -n <ns> --env <env> --tail 200 --since 30m
```

Drop to `kubectl` against the data plane only when you need shape `occ component logs` doesn't expose — `kubectl describe pod` for events / image-pull state, `kubectl get pod -n <runtime-ns> -l <selector>` for restart counts. The data plane may be the same cluster as the control plane (single-cluster installs) or a separate cluster (multi-cluster); get its kubeconfig from your platform team or the `DataPlane` CR.

## Ready ≠ working

Two failure modes hide behind `Ready=True`:

1. **Crash-loop flapping.** A container can start, briefly report Ready, then crash. The next probe sees Ready=False, then Ready again after restart. Check the logs via `occ component logs <component> -n <ns> --env <env>` for the crash trace; for restart counts specifically (which `occ` doesn't surface today), drop to `kubectl get pod -n <runtime-ns> -l openchoreo.dev/component=<component>`.

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

If the message points at a build / workflow run, get the run logs via `occ`:

```bash
occ component workflowrun logs <component> -n <ns>           # latest run for the component
occ workflowrun logs <run-name> -n <ns>                      # specific run
occ workflowrun logs <run-name> -n <ns> -f --since 5m        # live, recent
```

`occ workflowrun logs` fetches from the workflow plane for live runs and the observer for completed runs — no need to know the workflow plane's namespace (e.g. `workflows-default`) or pick a pod by name.

For downstream controllers (Argo Workflows, ESO, the OpenChoreo controller-manager itself), drop to `kubectl logs` — `occ` doesn't expose controller logs:

```bash
kubectl logs -n <controller-ns> deployment/<controller> --tail=200
# Typical:
#   openchoreo-controller-manager in openchoreo-control-plane
#   external-secrets in external-secrets
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

For runtime questions — container crash-looping, OOM, app log output — reach for the most-`occ`-shaped tool first:

- **`occ component logs <component> -n <ns> --env <env>`** — pod logs. Routes to the right data plane, falls back to the observer for archived logs.
- **`occ component workflowrun logs <component> -n <ns>`** — build / workflow run logs.
- **`kubectl`** against the data plane only when `occ` doesn't cover the shape — pod events (`describe pod`), restart counts (`get pod`), namespaced controller logs.
- **The observability backend** (Grafana, OpenSearch, Loki, Prometheus, Tempo) for historical logs / metrics / traces.

## Gotchas

- **Flux's interval is 5m for Kustomizations.** If a deploy "isn't happening", you may just be waiting. `flux reconcile --with-source` to push the next cycle.
- **`occ` reads the cluster, not Git.** When you want to know what's deployed, `occ get`. When you want to know what should be deployed, `git show`. They should agree.
- **Don't chase pod logs from a stuck Kustomization.** If `flux get kustomizations` shows the Kustomization isn't READY, no controller has touched your resource yet — pod-level evidence is irrelevant. Fix the Kustomization first.
- **Three "Ready"s in different conditions.** `Flux Kustomization Ready`, `OpenChoreo Component Ready`, `ReleaseBinding Ready` — different layers. Read the message, not just the status.
- **Don't `kubectl get workload` / `kubectl get workflow.argoproj.io`.** Both have `occ` wrappers: `occ workload get <name> -n <ns>` (outputs YAML by default) and `occ workflowrun list/get -n <ns>` (which wraps the underlying Argo Workflow). Drop to `kubectl` only when you specifically want raw Argo state or downstream K8s resources `occ` doesn't surface.

## Related

- [`../concepts.md`](../concepts.md) *Verification ladder*, *Drift recovery*
- [`onboard-component-byo.md`](./onboard-component-byo.md), [`onboard-component-source-build.md`](./onboard-component-source-build.md)
- [`promote.md`](./promote.md), [`bulk-promote.md`](./bulk-promote.md)
- `occ component logs` / `occ workflowrun logs` / `occ component workflowrun logs` — runtime + build logs (prefer over `kubectl`)
- `kubectl` against the data plane — fall back to it only for pod events / restart counts / controller logs
