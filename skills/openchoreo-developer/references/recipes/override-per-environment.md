# Override per environment

Customise replicas, resources, env vars, files, and trait parameters per environment without changing the base Component or Workload. Lives in the `ReleaseBinding` for that environment.

## When to use

- Production needs more replicas / CPU / memory than dev
- Different log level (`debug` in dev, `warn` in prod)
- Different secret reference per environment (different DB credentials)
- Disable a trait in some environments, enable in others
- Different feature-flag config files per environment
- For changes that should apply to *every* environment, edit the base Workload via `recipes/configure-workload.md` instead

## Prerequisites

A `ReleaseBinding` already exists for the target environment. Created automatically when:

- `auto_deploy: true` on the Component creates the first env's binding
- A subsequent env was promoted via `recipes/deploy-and-promote.md`

To list bindings:

```yaml
list_release_bindings
  namespace_name: default
  component_name: my-service
```

## Override priority

```text
ComponentType defaults
  ↓ overridden by
Component spec.parameters
  ↓ overridden by
ReleaseBinding componentTypeEnvironmentConfigs / traitEnvironmentConfigs / workloadOverrides
```

Most specific wins. The ReleaseBinding is the per-environment last word.

## Recipe

`update_release_binding` is a partial update — only the fields you pass are changed. Other fields (and the `release_name` itself) stay the same.

### Override replicas / resources

```yaml
update_release_binding
  namespace_name: default
  binding_name: my-service-production
  component_type_environment_configs:
    replicas: 3
    resources:
      requests: {cpu: "200m", memory: "256Mi"}
      limits:   {cpu: "1",    memory: "1Gi"}
```

The keys under `component_type_environment_configs` come from the ClusterComponentType's parameter schema:

```yaml
get_cluster_component_type_schema
  cct_name: deployment/service
```

### Override workload env vars / files

```yaml
update_release_binding
  namespace_name: default
  binding_name: my-service-production
  workload_overrides:
    container:
      env:
        - key: LOG_LEVEL
          value: warn
        - key: DB_HOST
          value: prod-db.internal
      files:
        - key: app.toml
          mountPath: /etc/app
          value: |
            mode = "production"
```

`workload_overrides` merges with the base Workload — matching keys are replaced, new keys are added. Removing a base env var requires a different approach; the override only adds or replaces.

### Override trait parameters

Use the trait's `instanceName` from the Component's `spec.traits[].instanceName`:

```yaml
update_release_binding
  namespace_name: default
  binding_name: my-service-production
  trait_environment_configs:
    high-error-rate:                  # the trait's instanceName
      enabled: true
      parameters:
        condition:
          threshold: 100              # tighter in prod
```

To disable a trait in this environment:

```yaml
trait_environment_configs:
  high-error-rate:
    enabled: false
```

### Combined override (typical prod-tightening)

```yaml
update_release_binding
  namespace_name: default
  binding_name: my-service-production
  component_type_environment_configs:
    replicas: 5
    resources:
      requests: {cpu: "500m", memory: "512Mi"}
      limits:   {cpu: "2",    memory: "2Gi"}
  trait_environment_configs:
    autoscaler:
      parameters:
        minReplicas: 5
        maxReplicas: 20
  workload_overrides:
    container:
      env:
        - key: LOG_LEVEL
          value: warn
```

### Verify

```yaml
get_release_binding
  namespace_name: default
  binding_name: my-service-production
```

Check `status.conditions[]` for `Ready: True`, `Synced: True`. Then verify runtime behaviour with `recipes/inspect-and-debug.md`.

## Patterns

### Tighten alert threshold in prod

```yaml
trait_environment_configs:
  high-error-rate:
    parameters:
      condition:
        threshold: 50            # base was 200; prod is more sensitive
```

### Different secret per environment

The base Workload references a SecretReference name (e.g. `db-secret`). Per-env secrets need *different* SecretReference resources (e.g. `db-secret-staging`, `db-secret-prod`) and an override that points at the env-specific one:

```yaml
workload_overrides:
  container:
    env:
      - key: DB_PASSWORD
        valueFrom:
          secretKeyRef:
            name: db-secret-prod         # overrides the base reference
            key: password
```

### Disable a trait in dev

```yaml
trait_environment_configs:
  observability-alert-rule:
    enabled: false
```

## Gotchas

- **`update_release_binding` is partial** — only the fields you pass are changed. Omitting a field is "leave alone," not "delete." To clear an override, set it to the base value explicitly.
- **`workload_overrides` is merge, not replace.** Existing env vars and files in the base stay; matching keys get overridden; new keys get added. There is no "remove this base env var" semantics.
- **Trait override keys are `instanceName`, not the trait `name`.** A Component can attach the same trait twice with different `instanceName`s; the override targets one specific instance.
- **Trait override fields go under `parameters` (or `enabled` at the top level).** Use the trait's parameter schema (`get_cluster_trait_schema cct_name: <trait>`) to know what's overridable.
- **The override only takes effect after the controller reconciles.** Watch `status.conditions` on the binding for `Synced: True` before assuming the change is live.
- **Override priority surprises.** ReleaseBinding > Component `parameters` > ClusterComponentType defaults. If a Component sets `parameters.replicas: 2` and the ReleaseBinding overrides to `replicas: 5`, prod runs 5. If the ReleaseBinding doesn't set replicas, prod inherits the Component's 2.
- **Promotion does not copy overrides forward.** Each environment's ReleaseBinding has independent overrides. Promoting from dev → staging creates a fresh staging binding with no overrides; you re-apply each env's override deliberately.
- **Updating a base Workload triggers a new ComponentRelease.** Existing ReleaseBindings keep their overrides but may need a `release_name` bump (via `update_release_binding release_name: <new>`) to pick up the new release. `auto_deploy: true` handles this for the first env only.

## Related recipes

- [`configure-workload.md`](configure-workload.md) — base Workload configuration (applies to every environment)
- [`deploy-and-promote.md`](deploy-and-promote.md) — promotion creates the bindings you'll override
- [`manage-secrets.md`](manage-secrets.md) — env-specific secrets pattern
- [`inspect-and-debug.md`](inspect-and-debug.md) — verify the override took effect
