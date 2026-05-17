# OpenChoreo on K3d Locally

Bootstrap OpenChoreo on a local k3d cluster. The k3d guide is fully opinionated, so this playbook is mostly straight execution.

> **Disclaimer:** the fetched install guide is the source of truth. If anything here conflicts with the guide, follow the guide.

## Step 1 — Capture choices

Apply silent defaults unless the user opted out. Summarise resolved choices before running anything.

| Decision | Options | Default |
| --- | --- | --- |
| **OpenChoreo version** | latest stable / specific minor / bleeding edge (`next`) | latest stable (the fetch script resolves it and prints on stderr) |
| **Optional planes** | Workflow, Observability | install both; skip one only if the user opted out (control + data planes always install) |
| **Default platform resources** | yes / no | yes; skip only if the user opted out (without these no apps can deploy) |

The guide's "Try it out" sections (deploy a sample, build from source) are opt-in. Walk past them during install; offer them after.

## Step 2 — Fetch the install guide

Run from the skill root:

```bash
./scripts/fetch-page.sh --title "On K3d Locally"
./scripts/fetch-page.sh --title "On K3d Locally" --version v1.0.x   # pin a minor
./scripts/fetch-page.sh --title "On K3d Locally" --version next     # bleeding edge
```

If the script exits non-zero, it has printed the version's `llms.txt`; pick the right URL and fetch it directly.

## Step 3 — Walk the guide

Top-to-bottom in the user's shell. Rules:

- **Skip plane sections the user opted out of** (the workflow plane is sometimes called "Build Plane").
- **Check the platform-specific tweaks below** before starting.
- **On failure, use judgment.** You have the cluster — `kubectl describe / logs / get events`, condition checks. If the cause is clear and the fix is in scope, fix it and continue; otherwise surface and ask. Don't silently substitute "equivalent" commands and don't strip `kubectl wait` calls. Keep a running note of any fix or deviation for the report.

## Step 4 — Report

Summarise what happened. Drop categories that don't apply.

- **Outcome** — success / partial (where did you stop?) / failed.
- **Version installed** and which planes are up and registered.
- **Choices applied** — opted-out planes, whether default platform resources were installed.
- **Workarounds applied** — anything that wasn't a straight read of the guide, and why.
- **Deviations from the guide** — commands not run as written, extra steps added during diagnose-and-fix.
- **Console URL and login**, copied from the guide.
- **Follow-ups** — opt-in "Try it out" sections, any day-2 platform work.

## Cleanup

`k3d cluster delete openchoreo`.

## Platform-specific tweaks

Things to watch for on specific runtimes.

### Apple Silicon — recommend Colima

Docker Desktop on M-series has buildpack issues. Suggest `colima start --vm-type=vz --vz-rosetta --cpu 4 --memory 8`. If their existing Docker works, don't push.

When using Colima, also `export K3D_FIX_DNS=0` before `k3d cluster create` — the guide mentions this in a `:::note` above the create command but it's easy to skim past.
