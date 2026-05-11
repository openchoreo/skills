# Recipe — Author AuthzRoles and Bindings via Git

OpenChoreo's authorization layer (separate from K8s RBAC). Two kinds + two binding kinds, both available cluster- and namespace-scoped:

| CRD                      | Path                                                       |
| ------------------------ | ---------------------------------------------------------- |
| `ClusterAuthzRole`       | `platform-shared/authz/roles/<name>.yaml`                  |
| `AuthzRole`              | `namespaces/<ns>/platform/authz/roles/<name>.yaml`         |
| `ClusterAuthzRoleBinding` | `platform-shared/authz/role-bindings/<name>.yaml`         |
| `AuthzRoleBinding`       | `namespaces/<ns>/platform/authz/role-bindings/<name>.yaml` |

For the conceptual model, read `authorization.md` first: <https://openchoreo.dev/docs/platform-engineer-guide/authorization.md>. The custom-roles companion: <https://openchoreo.dev/docs/platform-engineer-guide/authorization/custom-roles.md>.

## Preconditions

- Identity provider configured per <https://openchoreo.dev/docs/platform-engineer-guide/identity-configuration.md>. Without an IdP, the subjects in `AuthzRoleBinding` resolve to no one.

## Source the shapes

```text
https://openchoreo.dev/docs/reference/api/platform/authzrole.md
https://openchoreo.dev/docs/reference/api/platform/clusterauthzrole.md
https://openchoreo.dev/docs/reference/api/platform/authzrolebinding.md
https://openchoreo.dev/docs/reference/api/platform/clusterauthzrolebinding.md
```

Or template from cluster (if anything exists yet):

```bash
occ clusterauthzrole get platform-admin > /tmp/role.yaml
occ authzrolebinding list -n default
```

## Compose

```yaml
# shape: https://openchoreo.dev/docs/reference/api/platform/clusterauthzrole.md (occ v1.0.x)
apiVersion: openchoreo.dev/v1alpha1
kind: ClusterAuthzRole
metadata:
  name: platform-admin
spec:
  rules:
    - resources: ["*"]                    # OpenChoreo resource kinds
      verbs: ["*"]
    # Or scope down:
    # - resources: [ComponentType, Trait, Workflow]
    #   verbs: [get, list, create, update, delete]
```

```yaml
# shape: https://openchoreo.dev/docs/reference/api/platform/clusterauthzrolebinding.md (occ v1.0.x)
apiVersion: openchoreo.dev/v1alpha1
kind: ClusterAuthzRoleBinding
metadata:
  name: platform-team-admins
spec:
  roleRef:
    name: platform-admin
    kind: ClusterAuthzRole
  subjects:
    - kind: User
      name: alice@example.com
    - kind: Group
      name: platform-eng
```

Namespace-scoped variants are the same shape, with `metadata.namespace` set, `kind` swapped to `AuthzRole` / `AuthzRoleBinding`, and `roleRef.kind: AuthzRole` (if referencing a namespace-scoped role).

## Steps

1. **Decide scope** — cluster-wide capability vs namespace-bound. Most "developer" / "platform-admin" / "observability-reader" roles are cluster-scoped; tenancy-specific roles ("acme-team-admin") are namespace-scoped.
2. **Compose the spec** from the API ref. Keep `rules[]` minimal — least-privilege.
3. **Save** under the path from the table above.
4. **Commit + PR** (`platform/authz-<name>-<ts>` branch).
5. **Verify**:
   ```bash
   occ clusterauthzrole get <name>          # or namespace-scoped
   occ clusterauthzrolebinding list
   ```

Smoke-test by impersonating a subject:

```bash
occ login --credential <subject-creds>
occ component list -n <ns>                  # should reflect the role's verbs
```

## Variants

### Read-only developer role

```yaml
apiVersion: openchoreo.dev/v1alpha1
kind: ClusterAuthzRole
metadata:
  name: developer-readonly
spec:
  rules:
    - resources: [Project, Component, Workload, ReleaseBinding, ComponentRelease]
      verbs: [get, list]
    - resources: [WorkflowRun]
      verbs: [get, list]                  # no create / trigger
```

### Namespace-bound tenant admin

```yaml
apiVersion: openchoreo.dev/v1alpha1
kind: AuthzRole
metadata:
  name: tenant-admin
  namespace: acme
spec:
  rules:
    - resources: ["*"]                    # within this namespace
      verbs: ["*"]
```

Note the namespace boundary — the binding subject can do everything *within `acme`* but nothing in `platform-shared/` or other namespaces.

## Gotchas

- **`AuthzRole` is OpenChoreo authz, not K8s RBAC.** Don't confuse with `Role` / `ClusterRole` — those are separate and still apply to direct K8s API access.
- **Subjects depend on the IdP.** `User.name` and `Group.name` must match what the IdP issues. Verify the JWT claims your IdP emits before authoring bindings.
- **`Cluster*` and namespace-scoped variants are independent.** A `ClusterAuthzRoleBinding` granting `platform-admin` to alice doesn't grant her anything namespace-scoped resources unless the rule explicitly says so. Likewise, namespace `AuthzRoleBinding`s don't reach `platform-shared/`.
- **`roleRef` kind must match.** `AuthzRoleBinding` can reference `AuthzRole` (namespace-scoped) or `ClusterAuthzRole` (cluster-scoped). `ClusterAuthzRoleBinding` can only reference `ClusterAuthzRole`.
- **Bindings without an IdP are inert.** Authoring fine; nothing resolves until identity is wired.

## Related

- `authorization.md` — concepts
- `authorization/custom-roles.md` — `rules[]` shapes, examples
- `identity-configuration.md` — IdP setup (separate concern, but a hard prereq)
