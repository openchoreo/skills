# Recipe — Author AuthzRoles and Bindings via Git

OpenChoreo authz (separate from K8s RBAC). Two kinds + two binding kinds, each cluster- and namespace-scoped:

| CRD | Path |
| --- | --- |
| `ClusterAuthzRole` | `platform-shared/authz/roles/<name>.yaml` |
| `AuthzRole` | `namespaces/<ns>/platform/authz/roles/<name>.yaml` |
| `ClusterAuthzRoleBinding` | `platform-shared/authz/role-bindings/<name>.yaml` |
| `AuthzRoleBinding` | `namespaces/<ns>/platform/authz/role-bindings/<name>.yaml` |

A role declares `actions[]` (`<resource>:<verb>` strings, wildcards `<resource>:*` and `*`). A binding maps a subject (an IdP `entitlement` claim + value) to one or more roles via `roleMappings[]`, each optionally narrowed by `scope`, with `effect: allow | deny`. Cluster bindings can only reference cluster roles; namespace bindings can reference either. Bindings need an IdP wired — without one, subjects resolve to no one.

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
  actions:
    - "*"
```

```yaml
apiVersion: openchoreo.dev/v1alpha1
kind: ClusterAuthzRoleBinding
metadata:
  name: platform-team-admins
spec:
  entitlement:
    claim: groups
    value: platform-eng
  effect: allow
  roleMappings:
    - roleRef:
        kind: ClusterAuthzRole
        name: platform-admin
```

Namespace-scoped variants: same shape, set `metadata.namespace`, swap `kind` to `AuthzRole` / `AuthzRoleBinding`, set `roleRef.kind: AuthzRole` if pointing at a namespace-scoped role.

## Steps

1. Decide scope — cluster-wide capability vs namespace-bound tenant role.
2. Compose. Keep `actions[]` least-privilege. The live action set (with the lowest scope each applies at) is authoritative over any list here — the API serves it at `GET /api/v1/authz/actions` (MCP: `list_authz_actions`).
3. Save under the path from the table.
4. Commit + PR (`platform/authz-<name>-<ts>`).
5. Verify: `occ clusterauthzrole get <name>` (or namespace-scoped), `occ clusterauthzrolebinding list`.
6. Smoke-test by impersonating: `occ login --credential <subject-creds>` then `occ component list -n <ns>`.

## Common shapes

**Developer:**

```yaml
spec:
  actions:
    - "component:*"
    - "releaseline:*"                     # v1.4+: a component's release lines
    - "componentrelease:*"
    - "releasebinding:*"
    - "workload:*"
    - "workflowrun:view"
    - "workflowrun:create"
    - "project:view"
    - "environment:view"
```

**Read-only developer:**

```yaml
spec:
  actions:
    - "project:view"
    - "component:view"
    - "releaseline:view"                  # v1.4+
    - "workload:view"
    - "componentrelease:view"
    - "releasebinding:view"
    - "workflowrun:view"
```

**Namespace tenant admin:**

```yaml
kind: AuthzRole
metadata:
  name: tenant-admin
  namespace: acme
spec:
  actions:
    - "*"
```

The binding subject has full access *within `acme`* — nothing in `platform-shared/` or other namespaces.

## Gotchas

- **Not K8s RBAC.** `Role` / `ClusterRole` are separate and govern direct K8s API access independently.
- **Subjects depend on the IdP.** `entitlement.claim` / `entitlement.value` must match a claim your IdP emits (e.g. `groups` / `platform-eng`, or `sub` / a user ID).
- **`roleRef.kind` must match scope.** `ClusterAuthzRoleBinding` → only `ClusterAuthzRole`. `AuthzRoleBinding` → either.
- **No IdP, no resolution.** Authoring works; nothing takes effect until identity is wired.
- **Release lines need `releaseline:*` (v1.4+).** Only the chart's built-in roles got these actions on upgrade: `developer` and `platform-engineer` got all four, and `sre` and the system readers got `releaseline:view`. Custom roles without them can't list, create or delete a component's lines. A line's Workload, ComponentReleases and ReleaseBindings are still authorized by `workload:*` / `componentrelease:*` / `releasebinding:*` under the component's scope.
