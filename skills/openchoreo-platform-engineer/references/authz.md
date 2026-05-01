# Authorization (RBAC)

This file covers the **authorization surface** that platform engineers operate on a running OpenChoreo platform — defining roles, binding them to subjects, and reasoning about effective permissions.

It does **not** cover identity provider setup, JWT claim mapping configuration, or bootstrap mappings — those are install / setup concerns. See <https://openchoreo.dev/docs/platform-engineer-guide/authorization> for those.

> **MCP gap.** No MCP tools exist for `AuthzRole`, `ClusterAuthzRole`, `AuthzRoleBinding`, or `ClusterAuthzRoleBinding` — neither read nor write. All authz authoring goes through `kubectl apply -f`; inspect with `kubectl get <kind> <name> -o yaml`.

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

The full action catalogue is in §7.

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

| CRD | Scope | Purpose |
|---|---|---|
| `ClusterAuthzRole` | cluster | Define a set of allowed actions, available across all namespaces |
| `AuthzRole` | namespace | Define actions scoped to a single namespace |
| `ClusterAuthzRoleBinding` | cluster | Bind an entitlement to one or more cluster roles, optionally narrowed via `scope` |
| `AuthzRoleBinding` | namespace | Bind an entitlement to one or more roles within a namespace |

Use cluster roles for cross-cutting concerns (PE-level access, organization-wide auditors). Use namespace roles when a tenant team needs its own role definitions.

`AuthzRoleBinding` may reference both `AuthzRole` and `ClusterAuthzRole`. `ClusterAuthzRoleBinding` may only reference `ClusterAuthzRole`.

---

## 4. Role authoring

### `ClusterAuthzRole`

```yaml
apiVersion: openchoreo.dev/v1alpha1
kind: ClusterAuthzRole
metadata:
  name: platform-admin
spec:
  actions:
    - "*"                                    # everything
```

```yaml
apiVersion: openchoreo.dev/v1alpha1
kind: ClusterAuthzRole
metadata:
  name: developer
spec:
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

```yaml
apiVersion: openchoreo.dev/v1alpha1
kind: ClusterAuthzRole
metadata:
  name: viewer
spec:
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

Same shape, but namespace-scoped:

```yaml
apiVersion: openchoreo.dev/v1alpha1
kind: AuthzRole
metadata:
  name: tenant-developer
  namespace: acme
spec:
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

---

## 5. Role binding authoring

A binding has three parts:

- A **subject** (entitlement claim + value)
- One or more **role mappings** (each a roleRef + optional scope)
- An **effect** (`allow` or `deny`)

### `ClusterAuthzRoleBinding`

Cluster-wide grant:

```yaml
apiVersion: openchoreo.dev/v1alpha1
kind: ClusterAuthzRoleBinding
metadata:
  name: platform-team-cluster-admin
spec:
  entitlement:
    claim: groups
    value: platform-team
  effect: allow
  roleMappings:
    - roleRef:
        kind: ClusterAuthzRole
        name: platform-admin
```

Narrowed via scope (developer access in one project):

```yaml
apiVersion: openchoreo.dev/v1alpha1
kind: ClusterAuthzRoleBinding
metadata:
  name: crm-developers
spec:
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

Multiple role mappings in one binding (different scopes for different roles):

```yaml
apiVersion: openchoreo.dev/v1alpha1
kind: ClusterAuthzRoleBinding
metadata:
  name: alice-mixed
spec:
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

Targeted deny — block access on one project even though a broader allow grants it:

```yaml
apiVersion: openchoreo.dev/v1alpha1
kind: ClusterAuthzRoleBinding
metadata:
  name: deny-secret-project
spec:
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

Lives in a namespace and may only narrow scope within that namespace. May reference both `AuthzRole` and `ClusterAuthzRole`:

```yaml
apiVersion: openchoreo.dev/v1alpha1
kind: AuthzRoleBinding
metadata:
  name: crm-team-access
  namespace: acme
spec:
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

---

## 7. Available actions

These are the actions defined in the system. Use exact strings in role `spec.actions`, or wildcards (`<resource>:*`, `*`).

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

```bash
# Inspect roles
kubectl get clusterauthzrole                     # list
kubectl get clusterauthzrole <name> -o yaml      # full YAML, status
kubectl get authzrole -n <ns>                    # namespace-scoped list

# Inspect bindings
kubectl get clusterauthzrolebinding              # list
kubectl get clusterauthzrolebinding <name> -o yaml
kubectl get authzrolebinding -n <ns>

# Apply a new role / binding
kubectl apply -f my-role.yaml
kubectl apply -f my-binding.yaml
```

For the full CRD field reference, see <https://openchoreo.dev/docs/reference/api/platform/authzrole.md> (and the related `clusterauthzrole`, `authzrolebinding`, `clusterauthzrolebinding` API docs).
