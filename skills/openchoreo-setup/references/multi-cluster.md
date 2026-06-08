# OpenChoreo Multi-Cluster

Bootstrap OpenChoreo across multiple Kubernetes clusters: separate clusters per plane (full multi-cluster), CP+WP+OP co-located with remote DPs (hybrid), or central CP with multi-region DPs.

> **Disclaimer:** the fetched guides are the source of truth. If anything here conflicts with them, follow the guides. This reference covers choice-capture, gaps the guides don't mention, and the shape of the final report.

## Step 1 — Capture choices

Apply silent defaults unless the user opted out. Summarise resolved choices before running anything.

| Decision | Options | Default |
| --- | --- | --- |
| **OpenChoreo version** | latest stable / specific minor / bleeding edge (`next`) | latest stable (the fetch script resolves it and prints on stderr) |
| **Topology** | full multi-cluster (one cluster per plane) / hybrid (CP+WP+OP together, remote DPs) / multi-region (central CP, DPs per region) | ask the user — required, no default |
| **Cluster contexts** | one `kubectl` context per cluster, paired with the role each is for | ask the user — required, no default |
| **Cluster Gateway exposure** | LoadBalancer / TLS passthrough via kgateway | LoadBalancer; use TLS passthrough only if the user asked |
| **Optional planes** | Workflow, Observability | install both; skip one only if the user opted out |
| **Default platform resources** | yes / no | yes (without these no apps can deploy) |
| **Module overrides** | only honour what the user explicitly asked for | none. Catalogue: <https://openchoreo.dev/ecosystem/modules.md>. CloudWatch — push back. |

## Step 2 — Fetch the guides

Run from the skill root:

```bash
./scripts/fetch-page.sh --title "Run in Your Environment"       # per-cluster install steps
./scripts/fetch-page.sh --title "Multi-Cluster Connectivity"    # trust establishment + remote plane registration
./scripts/fetch-page.sh --title "Deployment Topology"           # topology background, prerequisite matrix, plane resource hierarchy
```

If any exits non-zero, it printed the version's `llms.txt`; pick the right URL and fetch it directly.

## Step 3 — Walk

Rules:

- **CP cluster first.** Install the CP per the OYE guide on the CP context. *During* the CP helm install, apply Step 0 of the multi-cluster connectivity guide: add `clusterGateway.tls.dnsNames` (or `ipAddresses`) for the public CP-gateway hostname remote agents will dial, and expose the cluster-gateway externally (`clusterGateway.service.type=LoadBalancer` by default, or TLS passthrough if chosen). Don't install DP/WP/OP on the CP cluster unless the topology co-locates them there.
- **Per remote plane**, switch context and follow Steps 1–4 of the multi-cluster connectivity guide: install that plane's prerequisites (Gateway API + cert-manager + ESO + kgateway — WP needs only cert-manager + ESO), copy the CP CA into a ConfigMap, install the plane chart with `clusterAgent.serverUrl` pointing at the public CP-gateway URL, extract the agent CA, register the plane CRD in the CP cluster.
- **Cross-plane links** are patched on the CP cluster, not on the remote. The `observerURL` on the `ClusterObservabilityPlane` CRD must be externally reachable from the CP (no `svc.cluster.local`); use the OP's public gateway URL.
- **Cross-cluster telemetry**: observability collectors on the OP cluster can't scrape remote pods. On each remote DP/WP cluster install the relevant observability module(s) in push/collector-only mode, pointed at the OP's ingestion endpoints. Per-module setup lives in each module's README.
- **Apply module overrides only if the user asked for one** (Step 1). Same rule as single-cluster — skip the default's install command, follow the module's README at `https://github.com/openchoreo/community-modules/tree/main/<module-name>` instead.
- **Apply the platform-specific tweaks** (see [`on-your-environment.md`](./on-your-environment.md)'s "Platform-specific tweaks") per cluster as relevant.
- **On failure, use judgment.** You have the clusters — describe / logs / events on each, condition checks. If the cause is clear and the fix is in scope, fix it and continue; otherwise surface and ask. Don't strip `kubectl wait` calls. Keep a running note of any fix or deviation per cluster for the report.

## Step 3.5 — Verify before reporting

Multi-cluster has more easy-to-miss steps than single-cluster. Before declaring done, tick through:

- [ ] All three guides were fetched and walked (OYE for per-cluster install, multi-cluster-connectivity for trust, deployment-topology consulted for the prerequisite matrix).
- [ ] CP cluster: cluster-gateway certificate includes the public DNS name (or IP) remote agents dial — `kubectl get certificate cluster-gateway-tls -n openchoreo-control-plane -o jsonpath='{.spec.dnsNames}{.spec.ipAddresses}'`.
- [ ] CP cluster: cluster-gateway exposed externally (LoadBalancer has an external IP/hostname, or TLS passthrough route is accepted).
- [ ] Each remote cluster has its prerequisites installed (Gateway API + cert-manager + ESO + kgateway — WP needs only cert-manager + ESO).
- [ ] Each remote cluster has the CP CA in the `cluster-gateway-ca` ConfigMap in the plane's namespace.
- [ ] Each remote plane was installed with `clusterAgent.serverUrl` pointing at the public CP-gateway URL.
- [ ] Each remote plane's agent CA was extracted from the `cluster-agent-tls` Secret (`ca.crt`, NOT `tls.crt`) and embedded in the plane CRD registered on the CP.
- [ ] Each remote cluster-agent log shows `connected to control plane` — `kubectl --context <remote> logs -n <plane-ns> -l app=cluster-agent --tail=20 | grep -F 'connected to control plane'`.
- [ ] Each plane CRD on the CP shows the agent connected — `kubectl --context <cp> get clusterdataplane default -o jsonpath='{.status.agentConnection.connected}'` returns `true` (same for `clusterworkflowplane` / `clusterobservabilityplane`).
- [ ] CP-side health: `curl -sfk https://api.${CP_BASE_DOMAIN}/health`, `curl -sfk https://thunder.${CP_BASE_DOMAIN}/health/readiness`, `curl -sIk https://console.${CP_BASE_DOMAIN}/ | head -1` returns 200.
- [ ] CORS preflight from console → API works: `curl -sIk -X OPTIONS https://api.${CP_BASE_DOMAIN}/ -H "Origin: https://console.${CP_BASE_DOMAIN}" -H "Access-Control-Request-Method: GET" | grep -i "access-control-allow-origin"` returns the console origin.
- [ ] If OP was installed: `observerURL` on the `ClusterObservabilityPlane` CRD is externally reachable from the CP cluster (no `svc.cluster.local`); `curl -sfk` against it returns 200.
- [ ] If OP was installed: DP and WP (if installed) have `observabilityPlaneRef` patched.
- [ ] If OP was installed: the logs module's collection DaemonSet (e.g. fluent-bit) is Ready on the OP cluster *and* on each remote cluster you want logs from (DP, WP). The module must be installed on each remote cluster (push/collector-only mode) for the DS to exist there.
- [ ] Module overrides requested by the user were applied (default install commands skipped, alt module READMEs followed) — none if the user didn't ask.
- [ ] Platform-specific tweaks applied per cluster as relevant (RD pre-install, EKS observability-plane LB).
- [ ] Default platform resources applied to the CP (if the user didn't opt out).

Anything unchecked is a gap to surface in the report's "Deviations" line, not silently paper over.

## Step 4 — Report

Summarise per cluster. Drop categories that don't apply.

- **Outcome** — success / partial (where did you stop, on which cluster?) / failed.
- **Topology installed** — clusters and which plane(s) on each.
- **Version installed** and which planes are registered with the CP.
- **Choices applied** — opted-out planes, default platform resources, module overrides.
- **Workarounds applied** — per cluster, with reasons.
- **Deviations from the guides** — per cluster.
- **Console URL and login**, copied from the CP install. Self-signed cert acceptance per subdomain (`console`, `api`, `thunder`, observer if installed — each may sit on a different LB).
- **Production swap-outs** the user owns later: self-signed TLS issuer, OpenBao in dev mode, `ttl.sh` registry (if WP installed). Each is a one-knob change documented elsewhere.
- **Follow-ups** — opt-in "Try it" sections, any day-2 platform work.
