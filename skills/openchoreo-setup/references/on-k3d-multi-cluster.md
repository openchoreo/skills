# OpenChoreo on K3d Multi-Cluster

Bootstrap OpenChoreo across multiple local k3d clusters (one per plane). The official guide for this path is the README in `openchoreo/openchoreo`, not the docs site.

> **Disclaimer:** the fetched README is the source of truth. If anything here conflicts with it, follow the README. The README assumes a local checkout of `openchoreo/openchoreo` — commands use relative paths like `install/k3d/multi-cluster/config-cp.yaml` and `install/k3d/common/values-thunder.yaml`.

## Step 1 — Capture choices

Apply silent defaults unless the user opted out. Summarise resolved choices before running anything.

| Decision | Options | Default |
| --- | --- | --- |
| **OpenChoreo version** | latest stable / specific minor / bleeding edge (`main`) / pinned tag | latest stable. Allowed values are restricted to what `versions.json` lists (`./scripts/list-versions.sh`) plus `main`. Don't let the user pick a minor that's been dropped from `versions.json`. |
| **Optional planes** | Workflow, Observability | install both; skip one only if the user opted out (control + data planes always install) |
| **Default platform resources** | yes / no | yes (without these no apps can deploy) |
| **Module overrides** | only honour what the user explicitly asked for | none. Catalogue: <https://openchoreo.dev/ecosystem/modules.md>. CloudWatch — push back. |

## Step 2 — Resolve the ref and ensure a local checkout

Map the version choice to a git ref on `openchoreo/openchoreo`:

```bash
# allowed = ./scripts/list-versions.sh output (plus "main")
case "$chosen" in
  main|bleeding-edge|next)  ref=main ;;
  *.x)                                    # docs minor like v1.0.x → highest tag in that minor
    minor="${chosen%.x}"
    ref=$(git ls-remote --tags --refs https://github.com/openchoreo/openchoreo \
      | awk -F/ '{print $NF}' \
      | grep "^${minor//./\\.}\\." \
      | sort -V | tail -1) ;;
  *)                        ref="$chosen" ;;   # concrete tag from versions.json (e.g. v1.1.0-alpha-1)
esac
```

Then ensure the user has a local checkout at `$ref`. If they don't already, ask before cloning:

```bash
git clone --branch "$ref" --depth 1 https://github.com/openchoreo/openchoreo.git
cd openchoreo
```

If they do have a checkout, confirm the ref matches before running commands — relative paths in the README are checkout-relative.

Then read the README from the local checkout: `install/k3d/multi-cluster/README.md`.

## Step 3 — Walk

Run all commands from the repo root (so the README's relative paths resolve). Rules:

- **Skip plane sections the user opted out of** (the workflow plane is sometimes called "Build Plane").
- **Apply module overrides only if the user asked for one** (Step 1). Same rule as the other paths — skip the default's install command for that slot, follow the module's README at `https://github.com/openchoreo/community-modules/tree/main/<module-name>` instead.
- **On failure, use judgment.** Four clusters means four contexts (`k3d-openchoreo-cp`, `-dp`, `-wp`, `-op`) — make sure `--context` flags match the step. `kubectl describe / logs / get events` per cluster. Don't strip `kubectl wait` calls. Keep a running note of any fix or deviation per cluster for the report.

## Step 3.5 — Verify before reporting

Four clusters mean four context-scoped checks. Use `--context k3d-openchoreo-{cp,dp,wp,op}` for each.

- [ ] All four k3d clusters exist: `k3d cluster list | awk 'NR>1 {print $1}'` includes `openchoreo-cp`, `openchoreo-dp`, and (if installed) `openchoreo-wp` / `openchoreo-op`.
- [ ] **CP cluster**: all deployments Available across `openchoreo-control-plane` / `thunder` / `openbao`; `curl -sf http://api.openchoreo.localhost:8080/health`; `curl -sf http://thunder.openchoreo.localhost:8080/health/readiness`; `curl -sI http://openchoreo.localhost:8080 | head -1` returns 200.
- [ ] **DP cluster**: deployments Available in `openchoreo-data-plane`; cluster-agent log shows `connected to control plane` — `kubectl --context k3d-openchoreo-dp logs -n openchoreo-data-plane -l app=cluster-agent --tail=20 | grep -F 'connected to control plane'`.
- [ ] **CP cluster**: `ClusterDataPlane` shows the DP agent connected — `kubectl --context k3d-openchoreo-cp get clusterdataplane default -o jsonpath='{.status.agentConnection.connected}'` returns `true`.
- [ ] **WP cluster** (if installed): deployments Available; agent connected (same grep, swap namespace + context); `ClusterWorkflowPlane` `agentConnection.connected == true` on CP.
- [ ] **OP cluster** (if installed): deployments Available; agent connected; `ClusterObservabilityPlane` `agentConnection.connected == true` on CP; Observer health: `curl -sf http://observer.openchoreo.localhost:11080/health`.
- [ ] **Logs collection DS per cluster** (if OP installed): the logs module's DaemonSet (e.g. fluent-bit) is Ready on the OP cluster *and* on each remote cluster you want logs from (DP, WP). The module must be installed on each remote cluster (collector-only mode) for the DS to exist there.
- [ ] **Cross-plane links** (if OP installed): `kubectl --context k3d-openchoreo-cp get clusterdataplane default -o jsonpath='{.spec.observabilityPlaneRef.name}'` is non-empty; same for `clusterworkflowplane` if WP is installed.
- [ ] If WP installed: `kubectl --context k3d-openchoreo-wp get clusterworkflowtemplates` shows the checkout / build / publish / generate-workload templates.

Anything red → surface in the report's "Deviations" or "Outcome: partial", noting which cluster.

## Step 4 — Report

Summarise per cluster. Drop categories that don't apply.

- **Outcome** — success / partial (where did you stop, on which cluster?) / failed.
- **Version installed** — git ref + which clusters are up and registered.
- **Choices applied** — opted-out planes, whether default platform resources were installed, any module overrides.
- **Workarounds applied** — anything that wasn't a straight read of the README.
- **Deviations from the README** — commands not run as written, extra steps added during diagnose-and-fix.
- **Console URL and login**, copied from the README.
- **Follow-ups** — opt-in "Try it" sections in the README, any day-2 platform work.

## Cleanup

`k3d cluster delete openchoreo-cp openchoreo-dp openchoreo-wp openchoreo-op`.
