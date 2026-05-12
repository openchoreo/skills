# OpenChoreo on Your Environment

Bootstrap OpenChoreo on an existing Kubernetes cluster (k3s, GKE, EKS, AKS, DOKS, Rancher Desktop, or self-managed).

> **Disclaimer:** the fetched install guide is the source of truth. The cluster-fingerprint workarounds and production swap-outs below mirror what the guide already calls out — they're listed here so the agent can plan around them. If anything in this reference conflicts with the guide, follow the guide.

## Step 1 — Capture choices

Apply silent defaults unless the user opted out. Summarise the resolved choices before running anything.

| Decision | Options | Default |
| --- | --- | --- |
| **OpenChoreo version** | `Latest stable` / `Specific version` | `Latest stable`. The fetch script resolves it and prints the choice on stderr. |
| **Optional planes** (multi-select) | Workflow, Observability | Install both. Skip one only if the user explicitly opted out. Control plane + data plane always install. |
| **Default platform resources** | `Yes` / `No` | `Yes`. Skip only if the user explicitly opted out. Provisions whatever the guide's "Install Default Resources" step describes. |

The guide's "Try it out" sections are opt-in follow-ups, not part of the install. Offer them after; run only if asked.

## Step 2 — Fetch the install guide

Run from the skill root:

```bash
./scripts/fetch-page.sh --title "On Your Environment"
./scripts/fetch-page.sh --title "On Your Environment" --version v1.0.x   # pin a specific minor
```

If the script exits non-zero, it has printed the version's `llms.txt` to stdout; pick the right URL from the index and fetch it with `curl` or your harness's web-fetch tool.

## Step 3 — Walk the guide

The guide is the source of truth. Walk it top-to-bottom. Execution rules:

- **Skip optional plane sections the user did not select** (`Setup Workflow Plane (Optional)` / `Setup Observability Plane (Optional)` headings).
- **If the user opted out of default resources**, skip the "Install Default Resources" step and warn them that no application deploys are possible until they create their own.
- **Apply the applicable cluster-fingerprint workarounds (below)** as their relevant guide step comes up.
- **On failure, use judgment.** You have the cluster — `kubectl describe`, `kubectl logs`, `kubectl get events`, condition checks. If the cause is clear and the fix is in scope, fix it and continue. If you're not confident, surface what you found and let the user decide. Don't silently substitute a "should be equivalent" command, and don't strip `kubectl wait` calls. Keep a running note of anything you fixed or deviated from for the report.

### Rancher Desktop gotcha — applies BEFORE walking

If the cluster is Rancher Desktop, two settings have to change before the install begins, or the workflow plane will fail and traefik will fight kgateway:

- **Container runtime:** set to `containerd`. The default Docker/moby runtime trips `crun pids cgroup not available` on the workflow plane's build step.
- **Disable traefik.** It competes with kgateway for the 80/443 listeners.

Both live in Rancher Desktop → Preferences → Kubernetes. If `rdctl` is on PATH, the agent can change them headlessly — run `rdctl set --help` to find the exact flag names (they shift between versions), set the container engine to containerd and disable traefik, then restart Kubernetes (takes a few minutes). Tell the user what you're about to change first. If `rdctl` isn't available, walk the user through the GUI and wait for them to confirm before continuing.

### Cluster-fingerprint workarounds

Apply inline as the relevant guide step comes up. If the guide's `:::note` / `:::tip` / `<details>` says something different, follow the guide.

- **EKS — patch each gateway LB to `internet-facing`.** EKS defaults to internal LBs. Three patch points under `<details>` blocks labelled "EKS only: make the LoadBalancer internet-facing" (control-plane, data-plane, observability-plane gateway namespaces). `kubectl patch svc gateway-default -n <ns> -p` setting `service.beta.kubernetes.io/aws-load-balancer-scheme: internet-facing`.
- **Single-IP LoadBalancer — split ports across planes.** If the LB provider gives the same IP to multiple services (self-managed Kubernetes, MetalLB single-pool, bare-metal), gateways collide on 80/443. Pass `--set gateway.httpPort=<X>` `--set gateway.httpsPort=<Y>` per plane — the guide suggests DP `8080/8443`, OBS `9080/9443`. The `ClusterDataPlane` registration's `gateway.ingress.external.http.port` / `https.port` must match; read them back from `kubectl get gateway gateway-default -n openchoreo-data-plane -o jsonpath=...`.
- **Raw k3s on Docker runtime (not Rancher Desktop) — `crun pids cgroup` failure.** The `generate-workload-cr` build step fails; image build/push succeed. If switching the runtime isn't an option, apply the guide's `<details>` block "Workaround: manually create the Workload CR".
- **LoadBalancer returns hostname, not IP.** Common on EKS classic ELB. The guide's bash already falls back to `dig +short`. If `dig` isn't on the host, use `nslookup`, or have the user supply a real DNS domain via `CP_BASE_DOMAIN` / `DP_DOMAIN` / `OBS_BASE_DOMAIN` exports.
- **`nip.io` as default DNS.** Bases like `openchoreo.<ip-dashed>.nip.io` get free wildcard DNS; cert SANs reference these. If the user has their own DNS, substitute it in the same exports.

## Step 4 — Report

When the install finishes (or stops short), summarise what happened. Drop lines for categories that don't apply.

- **Outcome** — success, partial (which step did you stop at?), or failed.
- **Version installed** and which planes are up and registered.
- **Choices applied** — optional planes selected, whether default platform resources were installed.
- **Workarounds applied during install** — Rancher Desktop runtime / traefik change, EKS LB patch, single-IP port split, k3s cgroup fallback, etc. Note why each was needed.
- **Deviations from the guide** — commands you didn't run as written, extra steps you added during diagnose-and-fix, sections skipped beyond the user's opt-outs.
- **Console URL and login**, copied from the guide's "Log in" step. The user must accept self-signed certs separately for `console`, `api`, `thunder`, and (if installed) the observer subdomain.
- **Follow-ups the user owns** — the production swap-outs below, opt-in "Try it out" sections in the resolved guide, any day-2 platform work.

### Production swap-outs (surface in the report)

The install defaults to dev-grade. Defaults work for evaluation; surface these for the user to handle later. If the guide explicitly tells the user to do something different in their environment, follow the guide.

- **TLS issuer — self-signed `openchoreo-ca` (default).** Every `Certificate` references this `ClusterIssuer`, so swapping to a real CA (typically Let's Encrypt via ACME) is one change. Until then, browsers need to accept self-signed certs separately for each subdomain.
- **OpenBao mode — dev (default).** Installed with `server.dev.enabled=true` (in-memory, single replica). Data lost on pod restart. Production deployments need their own values with storage + unsealing — the OpenBao Helm chart docs cover the shape.
- **Container registry — `ttl.sh` (default, workflow plane only).** Images expire after 24h. Swap to ECR / GAR / ACR / GHCR by editing the `publish-image` `ClusterWorkflowTemplate`. Only matters if the workflow plane was installed.
