# OpenChoreo on K3d Locally

Bootstrap OpenChoreo on a local k3d cluster. The k3d guide is fully opinionated, so this playbook is mostly straight execution.

> **Disclaimer:** the fetched install guide is the source of truth. If anything in this reference conflicts with the guide, follow the guide.

## Step 1 — Capture choices

Apply silent defaults unless the user opted out. Summarise the resolved choices to the user before running anything.

| Decision | Options | Default |
| --- | --- | --- |
| **OpenChoreo version** | `Latest stable` / `Specific version` (e.g. `v1.0.x`) / `Bleeding edge (next)` | `Latest stable`. The fetch script resolves the choice and prints it on stderr. |
| **Optional planes** (multi-select) | Workflow, Observability | Install both. Skip one only if the user explicitly opted out. Control plane + data plane always install. |
| **Default platform resources** | `Yes` / `No` | `Yes`. Skip only if the user explicitly opted out. Provisions whatever the guide's "Install Default Resources" step describes. |

The guide's "Try it out" sections (deploy a sample, build from source) are opt-in follow-ups, not part of the install. Offer them after; run only if asked.

## Step 2 — Fetch the install guide

Run from the skill root:

```bash
./scripts/fetch-page.sh --title "On K3d Locally"
./scripts/fetch-page.sh --title "On K3d Locally" --version v1.0.x   # pin a specific minor
./scripts/fetch-page.sh --title "On K3d Locally" --version next     # bleeding edge (docs/next/)
```

The script prints the rendered Markdown to stdout. Save it and walk it in Step 3.

If the script exits non-zero, it has printed the version's `llms.txt` to stdout; pick the right URL from the index and fetch it with `curl` or your harness's web-fetch tool.

## Step 3 — Walk the guide

The guide is the source of truth. Walk it top-to-bottom in the user's shell. Execution rules:

- **Skip optional plane sections the user did not select** (`Setup Workflow Plane (Optional)` / `Setup Observability Plane (Optional)` headings).
- **If the user opted out of default resources**, skip the "Install Default Resources" step and warn them that no application deploys are possible until they create their own.
- **On failure, use judgment.** You have the cluster — `kubectl describe`, `kubectl logs`, `kubectl get events`, condition checks. If the cause is clear and the fix is in scope, fix it and continue. If you're not confident, surface what you found and let the user decide. Don't silently substitute a "should be equivalent" command, and don't strip `kubectl wait` calls. Keep a running note of anything you fixed or deviated from for the report.

### Easy-to-miss callouts

These live in the guide as `:::tip` / `:::note` blocks or inline lines, but they're easy to skip past:

- **Apple Silicon — recommend Colima.** Docker Desktop on M-series has buildpack issues. Suggest `colima start --vm-type=vz --vz-rosetta --cpu 4 --memory 8`. If their existing Docker works, don't push.
- **Colima needs `K3D_FIX_DNS=0`.** Set this before `k3d cluster create`; the guide says so but it's not part of the create command itself.
- **Fluent Bit needs `/etc/machine-id`.** Step 7 (observability) includes a `docker exec k3d-openchoreo-server-0 ...` to create it. Skip the line and the daemonset crash-loops.

## Step 4 — Report

When the install finishes (or stops short), summarise what happened. Drop lines for categories that don't apply.

- **Outcome** — success, partial (which step did you stop at?), or failed.
- **Version installed** and which planes are up and registered.
- **Choices applied** — optional planes selected, whether default platform resources were installed.
- **Workarounds applied during install** — anything from the easy-to-miss callouts that kicked in, and why each was needed.
- **Deviations from the guide** — commands you didn't run as written, extra steps you added during diagnose-and-fix, sections skipped beyond the user's opt-outs.
- **Console URL and login**, copied from the guide's "Log in" step.
- **Follow-ups the user owns** — opt-in "Try it out" sections in the resolved guide, any day-2 platform work.

## Cleanup

`k3d cluster delete openchoreo`.
