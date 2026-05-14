# Authorization (RBAC)

This file covers the **authorization surface** that platform engineers operate on a running OpenChoreo platform — defining roles, binding them to subjects, and reasoning about effective permissions.

It does **not** cover identity provider setup, JWT claim mapping configuration, or bootstrap mappings — those are install / setup concerns. See <https://openchoreo.dev/docs/platform-engineer-guide/authorization> for those.

## Tool surface

Authz is **MCP-first** and **scope-collapsed**. Each role / role-binding operation is one tool that takes a `scope` arg — `"namespace"` (default; the namespaced `AuthzRole` / `AuthzRoleBinding` in `namespace_name`) or `"cluster"` (the platform-wide `ClusterAuthzRole` / `ClusterAuthzRoleBinding`). These tools are net-new — there are no deprecated `*_cluster_*` aliases here.

- **Roles** — `list_authz_roles`, `get_authz_role`, `get_authz_role_creation_schema`, `create_authz_role`, `update_authz_role` *(full-spec replacement)*, `delete_authz_role`
- **Role bindings** — `list_authz_role_bindings`, `get_authz_role_binding`, `get_authz_role_binding_creation_schema`, `create_authz_role_binding`, `update_authz_role_binding` *(full-spec replacement)*, `delete_authz_role_binding`
- **Diagnostics** (flat — no `scope` arg) — `list_authz_actions` (the action catalogue, §7), `evaluate_authz` (debug allow/deny decisions, §6)

`create_*` / `update_*` take `name`, optional `display_name` / `description`, and a structured `spec` object — **not** a YAML file. The YAML blocks below show the `spec` shape; pass the equivalent object. `kubectl apply -f` remains a fine fallback for large edits or when you'd rather manage the diff as YAML — both paths produce the same end state.

Contents:

1. RBAC model — subject, action, scope, effect
2. Resource hierarchy and scope semantics
3. The four CRDs
4. Role authoring (`AuthzRole` / `ClusterAuthzRole`)
5. Role binding authoring (`AuthzRoleBinding` / `ClusterAuthzRoleBinding`)
6. How requests are evaluated (allow / deny precedence)
7. Available actions reference
8. Verification

---

## 1. RBAC model

Three pieces:

| Piece | Means | Source |
|---|---|---|
| **Subject** | _Who_ is making the request | Entitlements (claim:value pairs) extracted from JWT |
| **Action** | _What_ they want to do | `resource:verb` (e.g. `component:create`) |
| **Scope** | _Where_ in the resource hierarchy | Cluster / namespace / project / component |

A binding ties a subject to a role at a scope, with an effect (`allow` or `deny`).

### Subjects

Subjects are identified by **entitlements** — claim-value pairs from the caller's JWT/OIDC token:

- `groups:platformEngineer` — caller belongs to the `platformEngineer` group
- `sub:user-abc-123` — caller's unique identifier
- `email:alice@acme.com` — caller's email

A user can have multiple entitlements; each is evaluated independently.

### Actions

Format: `resource:verb`. Examples: `component:create`, `project:view`, `componenttype:delete`.

Wildcards:

- `component:*` — any verb on components
- `*` — any verb on any resource

The full action catalogue is in §7. Discover it at runtime with `list_authz_actions`.

### Effect

Each binding has `effect: allow | deny` (default `allow`). A `deny` is an explicit exception that revokes access an `allow` would otherwise grant.

---

## 2. Resource hierarchy and scope

Resources form a four-level ownership hierarchy:

```text
Cluster (everything)
  └── Namespace
        └── Project
              └── Component
```

**Scope** is the boundary that controls _where_ a binding's permissions apply. Resources outside the scope are invisible to that binding — as if the binding doesn't exist for them.

| Scope level | How to set | Applies to |
|---|---|---|
| Cluster-wide | omit `scope` on a `ClusterAuthzRoleBinding` | all resources at every level |
| Namespace | `scope.namespace: acme` | the `acme` namespace and everything inside it |
| Project | `scope.namespace: acme`, `scope.project: crm` | the `crm` project in `acme` and everything inside it |
| Component | `scope.namespace: acme`, `scope.project: crm`, `scope.component: backend` | only the `backend` component and its resources |

### Cascade rules

- **Permissions cascade downward.** A binding scoped to namespace `acme` covers every project and component within it.
- **Permissions do not cascade upward.** A binding scoped to project `crm` does **not** grant access to the namespace itself or to other projects. If you need that, add a separate role mapping at the appropriate scope.

### Effective permissions

The intersection of role and scope. A user can perform action X only if some binding **both** grants X **and** has the target resource within its scope.

Example — a `developer` role granting `component:create` and `project:view`:

| Binding scope | Effective permissions |
|---|---|
| `namespace: acme, project: crm` | Create components and view the project, only inside `crm`. Other projects in `acme` are unaffected. |
| `namespace: acme` | Create components and view projects across every project in `acme`. |
| (no scope, cluster) | Create components and view projects across the entire cluster. |

---

## 3. The four CRDs

| CRD | Scope | Purpose | MCP `scope` arg |
|---|---|---|---|
| `ClusterAuthzRole` | cluster | Define a set of allowed actions, available across all namespaces | `scope: "cluster"` |
| `AuthzRole` | namespace | Define actions scoped to a single namespace | `scope: "namespace"` (default) |
| `ClusterAuthzRoleBinding` | cluster | Bind an entitlement to one or more cluster roles, optionally narrowed via `scope` | `scope: "cluster"` |
| `AuthzRoleBinding` | namespace | Bind an entitlement to one or more roles within a namespace | `scope: "namespace"` (default) |

Use cluster roles for cross-cutting concerns (PE-level access, organization-wide auditors). Use namespace roles when a tenant team needs its own role definitions.

`AuthzRoleBinding` may reference both `AuthzRole` and `ClusterAuthzRole`. `ClusterAuthzRoleBinding` may only reference `ClusterAuthzRole`.

---

## 4. Role authoring

MCP-first flow:

1. `list_authz_actions` — discover valid `spec.actions[]` values before composing the spec.
2. `get_authz_role_creation_schema` (with `scope: "cluster"` for the `ClusterAuthzRole` variant) — fetch the spec shape.
3. `create_authz_role` — pass `name`, the `spec` object, optional `display_name` / `description`. `scope: "cluster"` creates a `ClusterAuthzRole`; omit it (or `scope: "namespace"` + `namespace_name`) for a namespaced `AuthzRole`.

The `spec` is `{ actions: [...] }` (min 1 action), with an optional `description`.

### `ClusterAuthzRole`

`create_authz_role` with `scope: "cluster"`, `name: platform-admin`, and this `spec`:

```yaml
actions:
  - "*"                                    # everything
```

`name: developer`, `spec`:

```yaml
actions:
  - "component:*"
  - "componentrelease:*"
  - "releasebinding:*"
  - "workload:*"
  - "project:view"
  - "environment:view"
  - "secretreference:view"
  - "logs:view"
  - "metrics:view"
  - "traces:view"
```

`name: viewer`, `spec`:

```yaml
actions:
  - "component:view"
  - "componentrelease:view"
  - "releasebinding:view"
  - "workload:view"
  - "project:view"
  - "environment:view"
  - "logs:view"
  - "metrics:view"
  - "traces:view"
  - "alerts:view"
  - "incidents:view"
```

### `AuthzRole` (namespace-scoped)

Same `spec` shape — `create_authz_role` with `scope: "namespace"`, `namespace_name: acme`, `name: tenant-developer`:

```yaml
actions:
  - "component:create"
  - "component:update"
  - "component:view"
  - "componentrelease:view"
  - "releasebinding:view"
```

### Patterns

- **Strict role** — explicit list of actions. Best for tenant-facing roles where you want to keep blast radius small.
- **Resource-wide wildcard** — `component:*` covers every verb on components. Good for ownership patterns.
- **Catch-all wildcard** — `*` only on internal admin roles; never give this to a tenant role.

### Updating a role

`update_authz_role` is **full-spec replacement** — omitted fields are deleted. Always read first:

```text
get_authz_role     scope: cluster, name: developer    → fetch the current spec
# modify locally
update_authz_role  scope: cluster, name: developer    → send the entire modified spec
```

`delete_authz_role` leaves any binding that referenced the role **dangling** — run `list_authz_role_bindings` first to check what points at it.

---

## 5. Role binding authoring

A binding has three parts:

- A **subject** (entitlement claim + value)
- One or more **role mappings** (each a roleRef + optional scope)
- An **effect** (`allow` or `deny`)

MCP-first flow: `get_authz_role_binding_creation_schema` (scope-aware), then `create_authz_role_binding` with `name` + `spec`. **The schema differs by scope** — cluster bindings reference only `ClusterAuthzRole` and may set `scope.namespace`; namespace bindings reference either kind and may only set `scope.project` / `scope.component`. Always fetch the schema for the scope you're authoring.

### `ClusterAuthzRoleBinding`

`create_authz_role_binding` with `scope: "cluster"`, `name: platform-team-cluster-admin`, `spec`:

```yaml
entitlement:
  claim: groups
  value: platform-team
effect: allow
roleMappings:
  - roleRef:
      kind: ClusterAuthzRole
      name: platform-admin
```

Narrowed via scope (developer access in one project) — `name: crm-developers`, `spec`:

```yaml
entitlement:
  claim: groups
  value: crm-developers
effect: allow
roleMappings:
  - roleRef:
      kind: ClusterAuthzRole
      name: developer
    scope:
      namespace: acme
      project: crm
```

Multiple role mappings in one binding (different scopes for different roles) — `name: alice-mixed`, `spec`:

```yaml
entitlement:
  claim: sub
  value: user-alice-123
effect: allow
roleMappings:
  - roleRef:
      kind: ClusterAuthzRole
      name: developer
    scope:
      namespace: acme
      project: crm
  - roleRef:
      kind: ClusterAuthzRole
      name: viewer                  # cluster-wide read access
```

Targeted deny — block access on one project even though a broader allow grants it — `name: deny-secret-project`, `spec`:

```yaml
entitlement:
  claim: groups
  value: crm-developers
effect: deny
roleMappings:
  - roleRef:
      kind: ClusterAuthzRole
      name: developer
    scope:
      namespace: acme
      project: secret-project
```

### `AuthzRoleBinding` (namespace-scoped)

Lives in a namespace and may only narrow scope within that namespace (`scope.project` / `scope.component`, not `scope.namespace`). May reference both `AuthzRole` and `ClusterAuthzRole`. `create_authz_role_binding` with `scope: "namespace"`, `namespace_name: acme`, `name: crm-team-access`, `spec`:

```yaml
entitlement:
  claim: groups
  value: crm-team
effect: allow
roleMappings:
  - roleRef:
      kind: AuthzRole               # local role
      name: tenant-developer
    scope:
      project: crm
  - roleRef:
      kind: ClusterAuthzRole        # also a shared cluster role
      name: viewer
```

### Subject types

The `entitlement.claim` must match a claim configured for OpenChoreo's authorization layer. Common configured claims:

- `groups` — group membership (most common for human users)
- `sub` — unique subject ID (for service accounts, individual users)
- `email` — user email
- Custom claims defined by the IdP

The set of allowed claim names is configured at install time via Helm values. If a claim isn't recognized, no entitlement matches and the binding never fires.

### Updating a binding

`update_authz_role_binding` is **full-spec replacement** — `get_authz_role_binding` first, modify locally, send the whole spec back. `delete_authz_role_binding` revokes only what that binding granted; the referenced role remains.

---

## 6. How a request is evaluated

When a request arrives, OpenChoreo evaluates **every** role binding the subject matches. For each binding to apply, three things must be true:

1. **Subject matches** — one of the caller's entitlement values equals the binding's `entitlement.value` for the same `claim`.
2. **Resource is in scope** — the target resource lies at or below the binding's scope.
3. **Role grants the action** — the role's actions include the requested action exactly or via wildcard.

Decision rule:

> A request is **allowed** if and only if **at least one** matching binding has `effect: allow` **and** **no** matching binding has `effect: deny`.

A single matching `deny` is enough to block the request, even when multiple `allow` bindings would otherwise grant it. Deny applies across role kinds — a namespace-scoped `AuthzRoleBinding` with `effect: deny` can override a `ClusterAuthzRoleBinding` allow.

Use `deny` only for **targeted exceptions** to a broader allow. Default to `allow` and define narrow roles instead.

### Debugging decisions — `evaluate_authz`

When someone reports a `403` (or you want to confirm a binding does what you think), use `evaluate_authz` instead of reasoning by hand. It takes a `requests[]` array; each request is:

```text
{
  action: "component:create",
  resource: { type: "component", id?: ..., hierarchy?: ... },
  subject_context: { type: ..., entitlement_claim: "groups", entitlement_values: ["crm-developers"] },
  context?: ...
}
```

The response returns an allow/deny decision per request, and **on a deny includes the matching binding chain** — so you can see exactly which binding (or absence of one) produced the result. Use the affected user's own entitlements to answer "can they do X?".

---

## 7. Available actions

These are the actions defined in the system. Use exact strings in role `spec.actions`, or wildcards (`<resource>:*`, `*`). Discover the live set with `list_authz_actions` — it returns each action name plus the lowest scope it applies at (`cluster` | `namespace` | `project` | `component`). The tables below are a reference snapshot; `list_authz_actions` is authoritative.

### Application resources

| Resource | Actions |
|---|---|
| Namespace | `namespace:view`, `namespace:create`, `namespace:update`, `namespace:delete` |
| Project | `project:view`, `project:create`, `project:update`, `project:delete` |
| Component | `component:view`, `component:create`, `component:update`, `component:delete` |
| ComponentRelease | `componentrelease:view`, `componentrelease:create` |
| ReleaseBinding | `releasebinding:view`, `releasebinding:create`, `releasebinding:update`, `releasebinding:delete` |
| Workload | `workload:view`, `workload:create`, `workload:update`, `workload:delete` |
| WorkflowRun | `workflowrun:view`, `workflowrun:create`, `workflowrun:update` |
| Secrets | `secretreference:view`, `secretreference:create`, `secretreference:update`, `secretreference:delete` |

### Platform resources (PE)

| Resource | Actions |
|---|---|
| ComponentType | `componenttype:view`, `componenttype:create`, `componenttype:update`, `componenttype:delete` |
| ClusterComponentType | `clustercomponenttype:view`, `clustercomponenttype:create`, `clustercomponenttype:update`, `clustercomponenttype:delete` |
| Trait | `trait:view`, `trait:create`, `trait:update`, `trait:delete` |
| ClusterTrait | `clustertrait:view`, `clustertrait:create`, `clustertrait:update`, `clustertrait:delete` |
| Workflow | `workflow:view`, `workflow:create`, `workflow:update`, `workflow:delete` |
| ClusterWorkflow | `clusterworkflow:view`, `clusterworkflow:create`, `clusterworkflow:update`, `clusterworkflow:delete` |
| Environment | `environment:view`, `environment:create`, `environment:update`, `environment:delete` |
| DeploymentPipeline | `deploymentpipeline:view`, `deploymentpipeline:create`, `deploymentpipeline:update`, `deploymentpipeline:delete` |
| DataPlane | `dataplane:view`, `dataplane:create`, `dataplane:update`, `dataplane:delete` |
| ClusterDataPlane | `clusterdataplane:view`, `clusterdataplane:create`, `clusterdataplane:update`, `clusterdataplane:delete` |
| WorkflowPlane | `workflowplane:view`, `workflowplane:create`, `workflowplane:update`, `workflowplane:delete` |
| ClusterWorkflowPlane | `clusterworkflowplane:view`, `clusterworkflowplane:create`, `clusterworkflowplane:update`, `clusterworkflowplane:delete` |
| ObservabilityPlane | `observabilityplane:view`, `observabilityplane:create`, `observabilityplane:update`, `observabilityplane:delete` |
| ClusterObservabilityPlane | `clusterobservabilityplane:view`, `clusterobservabilityplane:create`, `clusterobservabilityplane:update`, `clusterobservabilityplane:delete` |
| NotificationChannel | `observabilityalertsnotificationchannel:view`, `observabilityalertsnotificationchannel:create`, `observabilityalertsnotificationchannel:update`, `observabilityalertsnotificationchannel:delete` |

### Authorization resources (meta)

| Resource | Actions |
|---|---|
| ClusterAuthzRole | `clusterauthzrole:view`, `clusterauthzrole:create`, `clusterauthzrole:update`, `clusterauthzrole:delete` |
| AuthzRole | `authzrole:view`, `authzrole:create`, `authzrole:update`, `authzrole:delete` |
| ClusterAuthzRoleBinding | `clusterauthzrolebinding:view`, `clusterauthzrolebinding:create`, `clusterauthzrolebinding:update`, `clusterauthzrolebinding:delete` |
| AuthzRoleBinding | `authzrolebinding:view`, `authzrolebinding:create`, `authzrolebinding:update`, `authzrolebinding:delete` |

### Observability and incidents

| Resource | Actions |
|---|---|
| Observability data | `logs:view`, `metrics:view`, `traces:view`, `alerts:view` |
| Incidents | `incidents:view`, `incidents:update` |
| RCA Report | `rcareport:view`, `rcareport:update` |

---

## 8. Verification

### MCP-first

```text
# Inspect roles (scope: cluster shown; omit scope or use namespace for namespaced roles)
list_authz_roles          scope: cluster
get_authz_role            scope: cluster, name: <name>          → full spec

# Inspect bindings
list_authz_role_bindings  scope: cluster
get_authz_role_binding    scope: cluster, name: <name>          → entitlement, role mappings, effect

# Confirm a decision lands the way you expect
evaluate_authz            requests: [ { action, resource, subject_context } ]   → allow/deny + binding chain
```

### `kubectl` fallback

For large edits, or when you'd rather review a YAML diff:

```bash
# Inspect
kubectl get clusterauthzrole                     # list
kubectl get clusterauthzrole <name> -o yaml      # full YAML, status
kubectl get authzrole -n <ns>                    # namespace-scoped list
kubectl get clusterauthzrolebinding              # list
kubectl get clusterauthzrolebinding <name> -o yaml
kubectl get authzrolebinding -n <ns>

# Apply a new role / binding
kubectl apply -f my-role.yaml
kubectl apply -f my-binding.yaml
```

Both paths produce the same end state.

For the full CRD field reference, see <https://openchoreo.dev/docs/reference/api/platform/authzrole.md> (and the related `clusterauthzrole`, `authzrolebinding`, `clusterauthzrolebinding` API docs).
