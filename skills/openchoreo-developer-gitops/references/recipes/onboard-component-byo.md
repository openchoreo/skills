# Recipe — Onboard a Component (BYO image)

End-to-end onboarding when you have a pre-built container image. Component without `spec.workflow`; Workload authored directly; ComponentRelease + ReleaseBinding generated via `occ`; PR + reconcile + verify.

For source-build (OpenChoreo builds from a Git repo), see [`onboard-component-source-build.md`](./onboard-component-source-build.md) instead.

## Preconditions

- This skill's Step 0 checks have passed (`occ` configured + cwd in a scaffolded GitOps repo).
- The Project exists (and its DeploymentPipeline + Environments). If not, author the Project file first (§ *Variant: create a Project* below) — same PR.
- A `ComponentType` matching the workload shape exists. Discover both scopes: `occ clustercomponenttype list` and `occ componenttype list -n <ns>`. Pick one.
- The image is published and pullable from the DataPlane.

## Steps

`<repo>` = GitOps repo root. `<ns>` = namespace. `<project>` = project. `<component>` = component name. `<image>` = container image ref (`registry/repo:tag`).

### 1. Scaffold the Component

```bash
mkdir -p "namespaces/<ns>/projects/<project>/components/<component>"

occ component scaffold <component> \
  --namespace <ns> --project <project> \
  --clustercomponenttype deployment/service \
  --clustertraits observability-alert-rule \
  -o "namespaces/<ns>/projects/<project>/components/<component>/component.yaml"
```

Adjust flags:

- Use `--componenttype` / `--traits` if the type / traits are namespace-scoped.
- **Drop the workflow flag entirely for BYO.** Adding `--clusterworkflow` makes this a source-build Component, which fails differently and won't match this recipe.

Open the file and fill in placeholders in `spec.parameters` and trait `parameters` blocks. The scaffold leaves comments explaining each.

### 2. Author the Workload

You have a choice:

**A. Hand-author the Workload CR directly.** Most explicit. Suitable for small workloads where the spec is short.

```yaml
# namespaces/<ns>/projects/<project>/components/<component>/workload.yaml
apiVersion: openchoreo.dev/v1alpha1
kind: Workload
metadata:
  name: <component>
  namespace: <ns>
spec:
  owner:
    componentName: <component>
    projectName: <project>
  container:
    image: <image>
    env:
      - key: LOG_LEVEL
        value: info
      - key: DB_PASSWORD
        valueFrom:
          secretKeyRef:
            name: db-credentials                  # a PE-authored SecretReference
            key: DB_PASSWORD
  endpoints:
    http:
      type: HTTP
      port: 8080
      visibility: [external]
```

> Field is `container.env[].key`, not `name`. Easy to typo.

**B. Synthesise via `occ workload create` from a descriptor.**

```bash
# Create a workload-descriptor first (or copy from another component as a starting point):
cat > /tmp/<component>-descriptor.yaml <<EOF
configurations:
  env:
    - name: LOG_LEVEL
      value: info
endpoints:
  - name: http
    type: HTTP
    port: 8080
    visibility: [external]
EOF

occ workload create \
  --mode file-system --root-dir <repo> \
  --project <project> --component <component> \
  --image <image> \
  --descriptor /tmp/<component>-descriptor.yaml
```

> The descriptor uses `configurations.env[].name` / `endpoints[].name`; the CR uses `container.env[].key` / endpoints as a map. `occ workload create` translates.

Either way: the output lands at `namespaces/<ns>/projects/<project>/components/<component>/workload.yaml`.

For deeper env / file / endpoint / dependency authoring, see [`./configure-workload.md`](./configure-workload.md). For wiring to other Components, [`./connect-components.md`](./connect-components.md).

### 3. Generate the ComponentRelease

```bash
occ componentrelease generate \
  --mode file-system --root-dir <repo> \
  --project <project> --component <component>
```

Writes `releases/<release-name>.yaml`. Default name is `<component>-<YYYYMMDD>-<n>`. Pass `--name <name>` to override (rarely needed).

### 4. Generate the ReleaseBinding(s)

**Ask the user first**: bind to the first environment only, or generate bindings across the pipeline?

- **First env only (default)** — one ReleaseBinding for the lowest env (typically `development`). Subsequent promotion via [`promote.md`](./promote.md) generates the rest as separate, deliberate commits.
- **All envs up-front** — only when the user explicitly asks. Useful for non-prod sandboxes, demos, or "deploy this everywhere now". Skip the gating intent of a promotion pipeline.

```bash
# First env only:
occ releasebinding generate \
  --mode file-system --root-dir <repo> \
  --project <project> --component <component> \
  --target-env development \
  --use-pipeline standard
```

Writes `release-bindings/<component>-development.yaml`. The release name is auto-resolved from the latest release in the repo; override with `--component-release <name>` for a specific one.

`--target-env` is required (since v1.0.x). Discover the root env from the project's pipeline: `occ deploymentpipeline get standard -n <ns>` and look at `spec.promotionPaths[0].sourceEnvironmentRef.name`.

For the all-envs path, loop the same command per env name from the pipeline. Each call writes one binding file.

### 5. Commit atomically on a feature branch, open a PR

Branch `release/<component>-<ts>`. Commit atomically — separate `Component` + `Workload` from `ComponentRelease` from `ReleaseBinding`(s). For multi-Component batches, commit per-Component. Canonical flow in [`../authoring.md`](../authoring.md) *Git workflow* (covers branch + push + PR + wait-for-merge).

### 6. Verify

Walk the verification ladder per [`../concepts.md`](../concepts.md) *Verification ladder*:

```bash
flux get sources git -A                              # READY=True, post-merge SHA
flux get kustomizations -A                           # READY=True, all stages

# OpenChoreo controllers reconciled:
occ component get <component> -n <ns>
occ workload get <component> -n <ns>                  # or <component>-workload depending on naming
occ releasebinding get <component>-development -n <ns>
# Watch: ReleaseSynced → ResourcesReady → Ready
```

To skip the 5m Kustomization interval:

```bash
flux reconcile kustomization <name> --with-source
```

For public-facing services, curl one of `status.endpoints[]` on the ReleaseBinding to confirm functional readiness. `Ready=True` means reconciled, not necessarily working.

### 7. (Optional) Promote to the next environment

See [`promote.md`](./promote.md).

## Variant: create a Project (first onboard in a namespace)

If the Project doesn't exist yet, author `project.yaml` in the same PR.

```yaml
# namespaces/<ns>/projects/<project>/project.yaml
apiVersion: openchoreo.dev/v1alpha1
kind: Project
metadata:
  name: <project>
  namespace: <ns>
  annotations:
    openchoreo.dev/display-name: <Display Name>
    openchoreo.dev/description: <human-readable description>
spec:
  deploymentPipelineRef:
    name: standard                                  # whichever pipeline the PE authored
    # kind: DeploymentPipeline                      # optional; defaults to DeploymentPipeline
```

Add to the same PR as the Component. Flux applies based on content, not order — the Project will reconcile alongside the Component.

> **`deploymentPipelineRef` is an object, not a plain string.** Easy to typo as `deploymentPipelineRef: standard` — that fails validation.

## Variant: BYO with autoDeploy off

If the user wants a human gate even for the first environment, set `spec.autoDeploy: false` on the Component. The controller won't auto-create a ReleaseBinding — the one from `occ releasebinding generate` in step 4 is the only path. Subsequent releases also need explicit bindings.

## Gotchas

- **`component_type` is a single string** in `<workloadType>/<name>` form. The scaffold's `--clustercomponenttype deployment/service` is right; `--clustercomponenttype service` is wrong.
- **For BYO, do not pass `--workflow` / `--clusterworkflow`** to the scaffold. That turns it into a source-build Component.
- **For BYO, you create the Workload yourself.** Source-build Components auto-generate `<component>-workload`; never `occ workload create` for those.
- **`Workload.spec.owner` (projectName + componentName) is immutable.** Pick names carefully.
- **`env` / `files` entries need exactly one of `value` or `valueFrom`** — not both, not neither.
- **`auto_deploy: true` only deploys to the first environment** in the pipeline. Promotion to staging / prod uses `occ releasebinding generate` per env.
- **Trust the ReleaseBinding `status.endpoints[]` for the deployed URL.** Don't construct hostnames from Component name + env guess — gateway routes vary.

## Related

- [`onboard-component-source-build.md`](./onboard-component-source-build.md) — alternative path: OpenChoreo builds from source
- [`configure-workload.md`](./configure-workload.md) — env vars, files, endpoints, multi-container detail
- [`connect-components.md`](./connect-components.md) — declare dependencies between components
- [`attach-trait.md`](./attach-trait.md) — attach a PE-authored Trait
- [`promote.md`](./promote.md) — promote to staging / prod
- [`verify-and-debug.md`](./verify-and-debug.md) — verify, troubleshoot, logs
- [`../concepts.md`](../concepts.md), [`../authoring.md`](../authoring.md)
