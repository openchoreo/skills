# OpenChoreo on Your Environment

Bootstrap OpenChoreo on an existing Kubernetes cluster (k3s, GKE, EKS, AKS, DOKS, Rancher Desktop, or self-managed).

> **Disclaimer:** the fetched install guide is the source of truth. If anything here conflicts with the guide, follow the guide. This reference covers choice-capture, gaps the guide doesn't mention, and the shape of the final report.

## Step 1 — Capture choices

Apply silent defaults unless the user opted out. Summarise resolved choices before running anything.

| Decision | Options | Default |
| --- | --- | --- |
| **OpenChoreo version** | latest stable / specific minor / bleeding edge (`next`) | latest stable (the fetch script resolves it and prints on stderr) |
| **Optional planes** | Workflow, Observability | install both; skip one only if the user opted out (control + data planes always install) |
| **Default platform resources** | yes / no | yes; skip only if the user opted out (without these no apps can deploy) |
| **Module overrides** | only honour what the user explicitly asked for | none — install with defaults (OpenSearch logs + tracing, Prometheus metrics, kgateway). Don't prompt or suggest alternatives. If the user named a module (e.g. "use OpenObserve for logs", "swap kgateway for Traefik"), apply it per Step 3. CloudWatch modules need AWS IAM + EventBridge setup — push back if the user asks for one. Catalogue: <https://openchoreo.dev/ecosystem/modules.md>. |

"Try it: ..." subsections in the guide are opt-in. Walk past them during install; offer them after.

## Step 2 — Fetch the install guide

Run from the skill root:

```bash
./scripts/fetch-page.sh --title "Run in Your Environment"
./scripts/fetch-page.sh --title "Run in Your Environment" --version v1.0.x   # pin a minor
./scripts/fetch-page.sh --title "Run in Your Environment" --version next     # bleeding edge
```

If the script exits non-zero, it has printed the version's `llms.txt`; pick the right URL and fetch it directly.

## Step 3 — Walk the guide

Top-to-bottom. Rules:

- **Skip plane sections the user opted out of** (the workflow plane is sometimes called "Build Plane").
- **Apply module overrides only if the user asked for one** (Step 1). For each requested non-default module, skip the default's install in the guide and follow the module's README at `https://github.com/openchoreo/community-modules/tree/main/<module-name>` instead. Logs/tracing/metrics: the obs-plane core still installs from the guide; only the per-signal `helm install` is replaced. Data-plane gateway: keep the kgateway install in the guide (CP and observability gateways still need it in single-cluster), then follow the alt gateway README to replace the data-plane `gateway-default` and upgrade the data-plane chart with `gatewayClassName=<x>`.
- **Check the platform-specific tweaks below** before starting and as relevant steps come up.
- **On failure, use judgment.** You have the cluster — `kubectl describe / logs / get events`, condition checks. If the cause is clear and the fix is in scope, fix it and continue; otherwise surface and ask. Don't silently substitute "equivalent" commands and don't strip `kubectl wait` calls. Keep a running note of any fix or deviation for the report.

## Step 3.5 — Verify before reporting

- [ ] All OpenChoreo deployments Available: `kubectl get deploy -A | awk 'NR>1 && $4!=$5'` should return zero rows for `openchoreo-*` / `thunder` / `openbao` namespaces.
- [ ] API health: `curl -sfk https://api.${CP_BASE_DOMAIN}/health`.
- [ ] Thunder readiness: `curl -sfk https://thunder.${CP_BASE_DOMAIN}/health/readiness`.
- [ ] Console returns 200: `curl -sIk https://console.${CP_BASE_DOMAIN}/ | head -1`.
- [ ] CORS preflight from console → API: `curl -sIk -X OPTIONS https://api.${CP_BASE_DOMAIN}/ -H "Origin: https://console.${CP_BASE_DOMAIN}" -H "Access-Control-Request-Method: GET" | grep -i "access-control-allow-origin"` returns the console origin (not `*`, not empty).
- [ ] If OP installed: Observer health: `curl -sfk https://observer.${OBS_BASE_DOMAIN}${OBS_PORT_SUFFIX}/health`.
- [ ] If OP installed: the logs module's collection DaemonSet (e.g. fluent-bit) is Ready in `openchoreo-observability-plane` (labels per the module's chart).
- [ ] If WP installed: `kubectl get clusterworkflowtemplates` shows the checkout / build / publish / generate-workload templates.
- [ ] Cluster-gateway certificate has the expected SANs: `kubectl get certificate cluster-gateway-tls -n openchoreo-control-plane -o jsonpath='{.spec.dnsNames}{.spec.ipAddresses}'` includes the public hostname or IP (only relevant if the user plans to add remote planes later).

Anything red → surface in the report's "Deviations" or "Outcome: partial".

## Step 4 — Report

Summarise what happened. Drop categories that don't apply.

- **Outcome** — success / partial (where did you stop?) / failed.
- **Version installed** and which planes are up and registered.
- **Choices applied** — opted-out planes, whether default platform resources were installed, any module overrides (e.g. OpenObserve logs, Traefik data-plane gateway).
- **Workarounds applied** — anything that wasn't a straight read of the guide, and why.
- **Deviations from the guide** — commands not run as written, extra steps added during diagnose-and-fix.
- **Console URL and login**, copied from the guide. The user must accept self-signed certs separately for each subdomain (`console`, `api`, `thunder`, and the observer if installed).
- **Production swap-outs** the user owns later: the self-signed TLS issuer, OpenBao running in dev mode, and (if the workflow plane was installed) the ephemeral `ttl.sh` registry. Each is a one-knob change documented elsewhere.
- **Follow-ups** — opt-in "Try it" sections, any day-2 platform work.

## Platform-specific tweaks

Things the guide doesn't (fully) cover. Apply only on the matching platform.

### Rancher Desktop — change two settings BEFORE Step 1

Otherwise the workflow plane will fail and traefik will fight kgateway:

- **Container runtime → containerd.** Default Docker/moby runtime trips `crun pids cgroup not available` on the build step.
- **Disable traefik.** Competes with kgateway for 80/443.

Both are in Rancher Desktop → Preferences → Kubernetes. If `rdctl` is on PATH, change them headlessly (run `rdctl set --help` for current flag names — they shift between versions), then restart Kubernetes. Tell the user what you're changing first. Without `rdctl`, walk them through the GUI and wait for confirmation.

### EKS — patch the observability-plane gateway

If the obs plane is installed, also patch its gateway to `internet-facing`. The guide has the patch under `<details>` for the control-plane and data-plane gateways but not for the observability-plane gateway, so the obs LB stays internal otherwise.

### GKE — fluent-bit logs module clashes with `fluentbit-gke`

Applies to any fluent-bit-based logs module — the default `opensearch` one, `openobserve`, `aws-cloudwatch` — not just to a module override. GKE's managed `fluentbit-gke` DaemonSet owns host port 2020, so install the logs module's fluent-bit with `hostNetwork: false`. That then breaks kubelet-based metadata enrichment — set the Kubernetes metadata filter to `Use_Kubelet Off` (API-server enrichment) or records ship with no `kubernetes.*` fields and the logs adapter rejects them (surfaces as observer 500s). Apply on every cluster running the logs collector.
