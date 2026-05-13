# Recipe — Author AuthzRoles and Bindings via Git

OpenChoreo authz (separate from K8s RBAC). Two kinds + two binding kinds, each cluster- and namespace-scoped:

| CRD | Path |
| --- | --- |
| `ClusterAuthzRole` | `platform-shared/authz/roles/<name>.yaml` |
| `AuthzRole` | `namespaces/<ns>/platform/authz/roles/<name>.yaml` |
| `ClusterAuthzRoleBinding` | `platform-shared/authz/role-bindings/<name>.yaml` |
| `AuthzRoleBinding` | `namespaces/<ns>/platform/authz/role-bindings/<name>.yaml` |

A role declares `rules[]` (resources × verbs). A binding attaches subjects (`User` / `Group`) to a role. Cluster bindings can only reference cluster roles; namespace bindings can reference either. Bindings need an IdP wired — without one, subjects resolve to no one.

## Source the shape

```bash
./scripts/fetch-page.sh --exact --title "ClusterAuthzRole"          # or "AuthzRole" / "ClusterAuthzRoleBinding" / "AuthzRoleBinding"
```

## Compose

```yaml
apiVersion: openchoreo.dev/v1alpha1
kind: ClusterAuthzRole
metadata:
  name: platform-admin
spec:
  rules:
    - resources: ["*"]
      verbs: ["*"]
```

```yaml
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

Namespace-scoped variants: same shape, set `metadata.namespace`, swap `kind` to `AuthzRole` / `AuthzRoleBinding`, set `roleRef.kind: AuthzRole` if pointing at a namespace-scoped role.

## Steps

1. Decide scope — cluster-wide capability vs namespace-bound tenant role.
2. Compose. Keep `rules[]` least-privilege.
3. Save under the path from the table.
4. Commit + PR (`platform/authz-<name>-<ts>`).
5. Verify: `occ clusterauthzrole get <name>` (or namespace-scoped), `occ clusterauthzrolebinding list`.
6. Smoke-test by impersonating: `occ login --credential <subject-creds>` then `occ component list -n <ns>`.

## Common shapes

**Read-only developer:**

```yaml
spec:
  rules:
    - resources: [Project, Component, Workload, ReleaseBinding, ComponentRelease]
      verbs: [get, list]
    - resources: [WorkflowRun]
      verbs: [get, list]
```

**Namespace tenant admin:**

```yaml
kind: AuthzRole
metadata:
  name: tenant-admin
  namespace: acme
spec:
  rules:
    - resources: ["*"]
      verbs: ["*"]
```

The binding subject has full access *within `acme`* — nothing in `platform-shared/` or other namespaces.

## Gotchas

- **Not K8s RBAC.** `Role` / `ClusterRole` are separate and govern direct K8s API access independently.
- **Subjects depend on the IdP.** `User.name` / `Group.name` must match the JWT claims your IdP emits.
- **`roleRef.kind` must match scope.** `ClusterAuthzRoleBinding` → only `ClusterAuthzRole`. `AuthzRoleBinding` → either.
- **No IdP, no resolution.** Authoring works; nothing takes effect until identity is wired.
