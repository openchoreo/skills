# Concepts

Read once per session before authoring. OpenChoreo abstracts away K8s for developers; in GitOps mode you commit OpenChoreo CRs to Git and Flux reconciles them onto the cluster, where OpenChoreo controllers render them into actual K8s objects (`Deployment`, `Service`, `HTTPRoute`, `NetworkPolicy`, …) on the DataPlane.

## Resource hierarchy

```text
Namespace (tenant boundary)
└── Project (bounded context — becomes a Cell at runtime)
    ├── Component                     (deployable unit; references a ComponentType)
    │   ├── Workload                  (runtime contract: image, ports, env, deps, files)
    │   ├── ComponentRelease          (immutable snapshot of Component+Workload+Type+Traits)
    │   ├── WorkflowRun               (build executions — IMPERATIVE; never in Git)
    │   └── ReleaseBinding            (binds a release to an Environment, with per-env overrides)
    ├── Environment                   (dev / staging / prod, maps to a DataPlane)
    ├── DeploymentPipeline            (promotion paths between environments)
    └── SecretReference               (pointers to external secret store entries)

Platform-shared (cluster-scoped; lives under platform-shared/):
├── ClusterComponentType / ComponentType
├── ClusterTrait / Trait
├── ClusterWorkflow / Workflow
└── ClusterAuthzRole / AuthzRole (and bindings)
```

This skill owns everything from `Environment` outward and the platform-shared layer. Application resources (`Project`, `Component`, `Workload`, `ComponentRelease`, `ReleaseBinding`) are application-side and out of scope. Plane resources (`DataPlane` / `WorkflowPlane` / `ObservabilityPlane` and their `Cluster*` variants) are install-side one-time setups and out of scope by default — see [`recipes/author-other-resources.md`](./recipes/author-other-resources.md).

## Repo layout (mono-repo default)

Per `gitops/overview.md`:

```text
.
├── platform-shared/                        # cluster-scoped resources
│   ├── component-types/                    # ClusterComponentType
│   ├── traits/                             # ClusterTrait
│   ├── workflows/                          # ClusterWorkflow
│   ├── authz/
│   │   ├── roles/                          # ClusterAuthzRole
│   │   └── role-bindings/                  # ClusterAuthzRoleBinding
│   └── cluster-workflow-templates/argo/    # Argo ClusterWorkflowTemplate CRDs
└── namespaces/<ns>/
    ├── namespace.yaml
    ├── platform/                           # namespace-scoped PE resources
    │   ├── infra/
    │   │   ├── deployment-pipelines/
    │   │   └── environments/
    │   ├── component-types/                # ComponentType
    │   ├── traits/                         # Trait
    │   ├── workflows/                      # Workflow
    │   ├── authz/
    │   │   ├── roles/
    │   │   └── role-bindings/
    │   ├── observability/
    │   │   ├── alert-rules/
    │   │   └── notification-channels/
    │   └── secret-references/
    └── projects/                           # developer-owned (skill boundary)
        └── <project>/
            ├── project.yaml
            └── components/<component>/...
```

Mono-repo is the default. `gitops/overview.md` documents multi-repo (platform + app split) and other variants (repo-per-project, repo-per-component, separate-releasebindings-repo, environment-based, hybrid) — the resource model doesn't change between them, only where the files live. Repo layout is a **user choice during scaffolding**; ask, don't impose.

## Sync layers (Flux CD)

Four `Kustomization`s, chained by `dependsOn` (per `gitops/using-flux-cd.mdx`):

1. **`namespaces/`** — every `<ns>/namespace.yaml`. Runs first so namespaces exist before namespace-scoped resources land.
2. **`platform-shared/`** — cluster-scoped resources.
3. **`namespaces/<ns>/platform/`** — namespace-scoped platform resources. `dependsOn: namespaces, platform-shared`.
4. **`namespaces/<ns>/projects/`** — application resources. `dependsOn: platform`.

Templates at [`../assets/flux/`](../assets/flux/). Documented reconciliation intervals: `GitRepository: 1m`, `Kustomization: 5m`.

## Cluster vs namespace scope

ComponentType / Trait / Workflow each have both scopes. Default OpenChoreo installs ship cluster-scoped variants visible to every namespace; namespace-scoped variants are an opt-in for per-tenancy isolation.

**They're interchangeable in shape.** Cluster→namespace conversion: swap `kind:` and add `metadata.namespace:`. Update referrers' `allowedWorkflows[].kind` / `allowedTraits[].kind` accordingly.

**Cross-scope rule.** A `ClusterComponentType` may only reference `ClusterTrait` / `ClusterWorkflow` in its `allowedTraits` / `allowedWorkflows`. A namespace-scoped `ComponentType` may reference both.

**`metadata.namespace`.** Cluster-scoped CRDs **must omit** it; namespace-scoped CRDs **must include** it.

Full mechanics in [`authoring.md`](./authoring.md) *Cluster ↔ namespace scope*.

## Vanilla CI workflows aren't GitOps-compatible

Critical gotcha. `dockerfile-builder` / `paketo-buildpacks-builder` / `gcp-buildpacks-builder` / `ballerina-buildpack-builder` write the `Workload` CR directly to the cluster API server — Flux would revert it on the next reconcile. Use the GitOps versions from `openchoreo/sample-gitops` (`docker-gitops-release` / `google-cloud-buildpacks-gitops-release` / `react-gitops-release` / `bulk-gitops-release`) instead. Details in [`authoring.md`](./authoring.md) *Vanilla CI workflows aren't GitOps-compatible*.

## Immutability and update semantics

- **`ComponentRelease` is immutable.** Regenerate with `occ componentrelease generate`; never hand-edit. (Developer-side.)
- **`Environment.spec.dataPlaneRef` is immutable.** Re-pointing requires delete + recreate, plus re-binding any `ReleaseBinding`s.
- **`ComponentType.spec.workloadType` is immutable.** Switching from `deployment` to `statefulset` requires delete + recreate.
- **`Project.spec.deploymentPipelineRef` is an object**, not a plain string (since v1.0.0). `kind` defaults to `DeploymentPipeline`.

In GitOps mode Flux re-applies the **full file** every reconcile — don't rely on partial-update semantics that some imperative tools expose. Editing half a spec in Git replaces the whole spec on the cluster.

## OpenGitOps principles

OpenChoreo follows the four [OpenGitOps](https://opengitops.dev/) principles: **declarative**, **versioned and immutable**, **pulled automatically** (Flux CD), and **continuously reconciled**.

Practical consequence: **Git is the source of truth; the cluster is its reflection.** `occ <kind> get <name>` against the cluster confirms reconciled state — if the live spec matches what Git declares, you're synced.

**Flux prunes on delete.** Removing a resource from Git deletes it from the cluster on the next reconcile. Useful for retiring resources cleanly; dangerous if you commit accidentally.

## API version

Every OpenChoreo CR: `apiVersion: openchoreo.dev/v1alpha1`.

## Verification ladder

After a PR merges:

1. **Flux pulled the new commit** — `flux get sources git -A`. Post-merge SHA prefix; `READY=True`.
2. **The relevant Kustomization applied** — `flux get kustomizations -A`. Identify by path. `READY=True` and `REVISION` matches the post-merge SHA. To skip the 5m wait: `flux reconcile kustomization <name> --with-source`. `dependsOn` means a stuck upstream blocks downstream.
3. **OpenChoreo controllers reconciled** — `occ <kind> get <name>` matches what Git declared. For PE-side resources, `status.conditions[]` shows no `Ready=False`. For ReleaseBindings (developer side), watch `ReleaseSynced` → `ResourcesReady` → `Ready`.

`flux events --for kustomization/<name>` and `--for gitrepository/<name>` are the diagnostic primitives when something is stuck.

## When stuck

- **`GitRepository` not advancing** — branch protection, push problem, or wrong `ref`. `flux events --for gitrepository/<name>`.
- **`Kustomization` failing** — usually a malformed manifest or missing dependency (cluster-scoped resource not yet in `platform-shared/`). `flux events --for kustomization/<name>`.
- **`Ready=False` on a PE resource** — controller validation failed. `occ <kind> get <name>` → `status.conditions[]` carries the message. Common causes: scope mismatch (e.g., `ClusterComponentType` referencing a namespace-scoped `Trait`), missing `default` on a required schema field, CEL referencing a context variable not available in that surface (see [`cel.md`](./cel.md)).
- **`WorkflowNotAllowed` on a Component** — the ComponentType's `allowedWorkflows[]` doesn't list the workflow the Component references. Often shows up after `Replace with defaults` if the vanilla CCT's `allowedWorkflows[]` wasn't rewritten to point at the GitOps Workflow names. See [`authoring.md`](./authoring.md) *Vanilla CI workflows aren't GitOps-compatible*.
- **Cluster diverged from Git after a clean reconcile** — see drift recovery below.

## Drift recovery

Drift = cluster spec ≠ Git spec for a GitOps-managed resource. Resolve by moving one side to match the other; **never `kubectl apply` against a GitOps-managed resource** — Flux reverts on the next reconcile (it does that on purpose).

1. **Compare** — `git -C <repo> show HEAD:<path>` vs `occ <kind> get <name>`.
2. **If Git is right** (cluster got hand-edited or stale), force Flux: `flux reconcile kustomization <name> --with-source`.
3. **If the cluster is right** (out-of-band change is the desired state but was never committed), codify back to Git:

   ```bash
   occ <kind> get <name> [-n <ns>] > /tmp/cluster.yaml
   # strip status:, metadata.managedFields:, metadata.creationTimestamp:, resourceVersion:, uid:
   # save to <repo>/<path>, commit, PR
   ```

4. **`ComponentRelease` is immutable** — if a release file in Git differs from the cluster, regenerate with `occ componentrelease generate` rather than hand-editing. (Developer-side; this skill rarely touches releases.)
