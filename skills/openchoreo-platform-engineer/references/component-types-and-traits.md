# ComponentTypes and Traits

This file is the authoring reference for **ComponentTypes**, **ClusterComponentTypes**, **Traits**, and **ClusterTraits** — the resources platform engineers create so developers have deployment templates and composable capabilities.

For the CEL expressions used throughout, see [`cel.md`](./cel.md). For Workflow authoring (build templates), see [`workflows.md`](./workflows.md). The full MCP tool list is discovered at runtime via the control-plane MCP server.

**Tool surface for these resources:** MCP-first, and **scope-collapsed** — `create_component_type` / `create_trait` (and their `get_*` / `update_*` / `delete_*` / `list_*` counterparts) each take a `scope` arg: `"namespace"` (default; the namespaced `ComponentType` / `Trait` in `namespace_name`) or `"cluster"` (the platform-wide `ClusterComponentType` / `ClusterTrait`). So `create_component_type` with `scope: "cluster"` is what authors a `ClusterComponentType`. They take a full `spec` body — discover the spec shape via `get_component_type_creation_schema` / `get_trait_creation_schema` (also `scope`-aware). `update_*` is **full-spec replacement**: read the current spec via `get_*` first, modify locally, send the whole spec back. The old `*_cluster_*` tool names still work as deprecated aliases (removed in v1.3) but use the canonical name + `scope`. For one-line CEL or template tweaks, `kubectl apply -f` against an edited YAML is often easier; both paths are equivalent.

Contents:

1. Concepts — what each resource does, scope rules
2. ComponentType authoring (structure, schema, resources)
3. Trait authoring (`creates`, `patches`, JSON Patch operations)
4. Schema syntax (`openAPIV3Schema`)
5. Validation rules
6. How developers consume these resources
7. Common patterns
8. Verification — MCP and `kubectl` flows

---

## 1. Concepts

| Resource | Scope | Defines |
|---|---|---|
| `ComponentType` | namespace | Workload kind, allowed traits, parameter schema, Kubernetes resource templates |
| `ClusterComponentType` | cluster-wide | Same shape as ComponentType; available in every namespace |
| `Trait` | namespace | Reusable capability — `creates` new resources and/or `patches` ComponentType resources |
| `ClusterTrait` | cluster-wide | Same shape as Trait; available in every namespace |

### Scope rules

- A `ClusterComponentType` may only reference `ClusterTrait` in `allowedTraits`.
- A `ComponentType` (namespaced) may reference both `Trait` and `ClusterTrait`.
- `ClusterComponentType` / `ClusterTrait` manifests **must not** include `metadata.namespace` — cluster-scoped resources reject it.
- **`ClusterTrait` does NOT support `spec.validations`.** Only namespace-scoped `Trait` does. The cluster-scoped variant rejects validations at create / update time.

### Workload types

`ComponentType.spec.workloadType` is one of:

- `deployment` — long-running Kubernetes Deployment
- `statefulset` — stateful workload (StatefulSet)
- `cronjob` — scheduled Job (CronJob)
- `job` — one-shot Job
- `proxy` — proxy / gateway pattern (no managed pods of its own)

The primary resource template's `id` must match the `workloadType` (`id: deployment` for `workloadType: deployment`, etc.). The platform uses this convention to find the workload.

### ComponentType reference format

When a developer references a ComponentType from a `Component`, the reference is `{workloadType}/{name}`:

```yaml
componentType:
  kind: ClusterComponentType        # or ComponentType
  name: deployment/web-service      # workloadType/name
```

Set `kind: ClusterComponentType` explicitly when using a default platform type — `kind` defaults to `ComponentType`.

---

## 2. ComponentType authoring

### Skeleton

```yaml
apiVersion: openchoreo.dev/v1alpha1
kind: ComponentType                  # or ClusterComponentType
metadata:
  name: web-service
  namespace: default                 # omit for ClusterComponentType
spec:
  workloadType: deployment

  allowedTraits:
    - kind: Trait                    # or ClusterTrait (must be ClusterTrait for ClusterComponentType)
      name: persistent-volume
    - kind: ClusterTrait
      name: autoscaler

  parameters:
    openAPIV3Schema:
      type: object
      properties: { ... }            # see Schema syntax

  environmentConfigs:
    openAPIV3Schema:
      type: object
      properties: { ... }            # per-env overrides; see Schema syntax

  validations:
    - rule: ${size(workload.endpoints) > 0}
      message: "Service components must expose at least one endpoint"

  resources:
    - id: deployment                 # must match workloadType
      template: { ... }              # Kubernetes resource with CEL expressions
    - id: service
      template: { ... }
    - id: httproute-external
      forEach: ${...}
      var: endpoint
      template: { ... }
```

### `parameters` vs `environmentConfigs`

- **`parameters`** — values from `Component.spec.parameters`. **Static** across environments. Set once when the developer authors the Component.
- **`environmentConfigs`** — values from `ReleaseBinding.spec.componentTypeEnvironmentConfigs`. **Per-environment**. Lets staging and production set different replica counts, resource limits, etc.

Both use the same `openAPIV3Schema` shape (see §4).

### `allowedTraits`

Allow-list of traits developers may attach to components of this type. Without this, developers can't use any traits with the type. The trait name must match exactly.

### `resources`

Each entry produces zero or more Kubernetes resources, generated from a CEL-templated `template`. Three control fields:

- **`id`** (required) — internal identifier; the entry whose `id` matches `workloadType` is the primary workload.
- **`includeWhen`** — entire field is a CEL expression. Resource is created only if it evaluates to true.
- **`forEach`** + **`var`** — repeat the template over a list or map. The loop variable is bound to `var`.

`includeWhen` is evaluated **before** `forEach` and controls the entire block. The loop variable is **not** available in `includeWhen`. For per-item filtering, use `.filter()` inside the `forEach` expression — see `cel.md`.

> **Admission rule (v1.0.0-rc.2+)**: resource templates **must not** hardcode `metadata.namespace`. Use `${metadata.namespace}` (the platform-resolved target namespace) instead. The webhook rejects literal namespace strings in `resources[].template.metadata.namespace`.

### Complete ComponentType example

```yaml
apiVersion: openchoreo.dev/v1alpha1
kind: ComponentType
metadata:
  name: web-service
  namespace: default
spec:
  workloadType: deployment

  allowedTraits:
    - kind: Trait
      name: persistent-volume
    - kind: Trait
      name: autoscaler

  parameters:
    openAPIV3Schema:
      type: object
      properties:
        replicas:
          type: integer
          default: 1
          minimum: 1
        serviceType:
          type: string
          enum: [ClusterIP, NodePort, LoadBalancer]
          default: ClusterIP

  environmentConfigs:
    openAPIV3Schema:
      type: object
      properties:
        resources:
          type: object
          default: {}
          properties:
            cpu:
              type: string
              default: "100m"
            memory:
              type: string
              default: "256Mi"

  validations:
    - rule: ${size(workload.endpoints) > 0}
      message: "Service components must expose at least one endpoint"

  resources:
    - id: deployment
      template:
        apiVersion: apps/v1
        kind: Deployment
        metadata:
          name: ${metadata.componentName}
          namespace: ${metadata.namespace}
          labels: ${metadata.labels}
        spec:
          replicas: ${parameters.replicas}
          selector:
            matchLabels: ${metadata.podSelectors}
          template:
            metadata:
              labels: ${metadata.podSelectors}
            spec:
              containers:
                - name: main
                  image: ${workload.container.image}
                  resources:
                    requests:
                      cpu: ${environmentConfigs.resources.cpu}
                      memory: ${environmentConfigs.resources.memory}
                  env: ${dependencies.toContainerEnvs()}
                  envFrom: ${configurations.toContainerEnvFrom()}
                  volumeMounts: ${configurations.toContainerVolumeMounts()}
              volumes: ${configurations.toVolumes()}

    - id: service
      includeWhen: ${size(workload.endpoints) > 0}
      template:
        apiVersion: v1
        kind: Service
        metadata:
          name: ${metadata.componentName}
          namespace: ${metadata.namespace}
        spec:
          selector: ${metadata.podSelectors}
          ports: ${workload.toServicePorts()}

    - id: httproute-external
      forEach: |
        ${workload.endpoints
          .transformList(name, ep, ("external" in ep.visibility && ep.type in ["HTTP", "GraphQL", "Websocket"]) ? [name] : [])
          .flatten()}
      var: endpoint
      template:
        apiVersion: gateway.networking.k8s.io/v1
        kind: HTTPRoute
        metadata:
          name: ${oc_generate_name(metadata.componentName, endpoint)}
          namespace: ${metadata.namespace}
          labels: ${oc_merge(metadata.labels, {"openchoreo.dev/endpoint-name": endpoint})}
        spec:
          parentRefs:
            - name: ${gateway.ingress.external.name}
              namespace: ${gateway.ingress.external.namespace}
          hostnames: |
            ${[gateway.ingress.external.?http, gateway.ingress.external.?https]
              .filter(g, g.hasValue()).map(g, g.value().host).distinct()
              .map(h, oc_dns_label(endpoint, metadata.componentName, metadata.environmentName, metadata.componentNamespace) + "." + h)}
          rules:
            - matches:
                - path:
                    type: PathPrefix
                    value: /${metadata.componentName}-${endpoint}
              filters:
                - type: URLRewrite
                  urlRewrite:
                    path:
                      type: ReplacePrefixMatch
                      replacePrefixMatch: ${workload.endpoints[endpoint].?basePath.orValue("/")}
              backendRefs:
                - name: ${metadata.componentName}
                  port: ${workload.endpoints[endpoint].port}
```

---

## 3. Trait authoring

A Trait augments a Component with operational behavior in two ways:

- **`creates`** — generate new Kubernetes resources alongside the component (PVCs, ExternalSecrets, ServiceMonitors, etc.)
- **`patches`** — modify resources already produced by the ComponentType (add a sidecar, inject a volume mount, append a label)

### Skeleton

```yaml
apiVersion: openchoreo.dev/v1alpha1
kind: Trait                          # or ClusterTrait
metadata:
  name: persistent-volume
  namespace: default                 # omit for ClusterTrait
spec:
  parameters:
    openAPIV3Schema: { ... }

  environmentConfigs:
    openAPIV3Schema: { ... }

  validations:
    - rule: ${...}
      message: "..."

  creates:
    - targetPlane: dataplane          # or observabilityplane (default: dataplane)
      includeWhen: ${...}             # CEL, optional
      template: { ... }

  patches:
    - target:
        kind: Deployment
        group: apps
        version: v1
        where: ${...}                 # CEL on `resource`, optional
      forEach: ${...}                 # optional
      var: item
      operations:
        - op: add | replace | remove
          path: /...
          value: ...
```

### Trait `instanceName`

Each trait attached to a component has a per-component `instanceName`. Developers pick it. It must be unique among that component's trait attachments. This lets a developer attach the same trait type multiple times with different configs (e.g., two persistent volumes).

In trait templates and patches, use `${trait.instanceName}` for naming so each attachment produces distinct resources:

```yaml
metadata:
  name: ${metadata.name}-${trait.instanceName}
```

### `creates`

Each `creates` entry generates one resource per evaluation. Same `template` / `includeWhen` / `forEach` / `var` semantics as ComponentType `resources`, plus:

- **`targetPlane`** — `dataplane` (default) or `observabilityplane`. Determines which plane the resource ships to.

```yaml
creates:
  - targetPlane: dataplane
    template:
      apiVersion: v1
      kind: PersistentVolumeClaim
      metadata:
        name: ${metadata.name}-${trait.instanceName}
        namespace: ${metadata.namespace}
      spec:
        accessModes: ["ReadWriteOnce"]
        storageClassName: ${environmentConfigs.storageClass}
        resources:
          requests:
            storage: ${environmentConfigs.size}
```

### `patches`

Patches modify resources produced by the ComponentType using JSON Patch operations (RFC 6902) extended with array filtering and CEL.

#### Target

```yaml
patches:
  - target:
      kind: Deployment
      group: apps                    # required; "" for core API resources
      version: v1
      where: ${resource.spec.replicas > 1}   # CEL on the candidate resource, optional
    operations: [ ... ]
```

`kind`, `group`, and `version` are required. For core API resources (Service, ConfigMap, Secret), set `group: ""`.

`where` is a CEL filter on the candidate resource. Only resources where the expression evaluates true are patched. The `resource` variable is the patch target — see `cel.md` availability matrix.

#### Operations

| Op | Behavior |
|---|---|
| `add` | Adds value at the path. Auto-creates missing parent maps. Use `/-` to append to an array. |
| `replace` | Replaces existing value. Errors if the path doesn't exist. |
| `remove` | Removes the value. Idempotent on map keys; errors on out-of-range array indices. |

```yaml
operations:
  - op: add
    path: /metadata/labels/monitoring
    value: enabled

  - op: add
    path: /spec/template/spec/containers/-          # `-` appends to array
    value:
      name: sidecar
      image: sidecar:latest

  - op: replace
    path: /spec/replicas
    value: 3

  - op: remove
    path: /metadata/labels/deprecated
```

#### Array filtering

Use JSONPath-like syntax to target array elements by field value:

```yaml
- op: add
  path: /spec/template/spec/containers[?(@.name=='main')]/env/-
  value:
    name: MONITORING
    value: enabled

- op: replace
  path: /spec/template/spec/volumes[?(@.name=='data')]/emptyDir
  value:
    sizeLimit: 10Gi

# Nested field filter
- op: replace
  path: /spec/containers[?(@.resources.limits.memory=='2Gi')]/image
  value: app:high-mem-v2
```

Filter form: `[?(@.field.path=='value')]`.

**Supported**: simple equality on a single field path.
**Not supported**: multiple conditions (`&&` / `||`), `contains`, array indexing inside filters, existence checks.

Prefer filters over positional indices like `[0]` — patches stay correct when the upstream resource changes order.

#### CEL in paths and values

```yaml
# Dynamic path segment
- op: add
  path: /data/${env.name}
  value: ${env.value}

# Dynamic filter
- op: add
  path: /spec/containers[?(@.name=='${parameters.containerName}')]/env/-
  value:
    name: VERSION
    value: ${parameters.version}

# Dynamic value (object)
- op: add
  path: /spec/template/spec/containers/-
  value:
    name: ${parameters.sidecarName}
    image: ${parameters.sidecarImage}
    ports:
      - containerPort: ${parameters.sidecarPort}
```

#### Path escaping (JSON Pointer)

| Special char | Escape |
|---|---|
| `/` in a key | `~1` |
| `~` in a key | `~0` |

Most often needed for Kubernetes annotations:

```yaml
- op: add
  path: /metadata/annotations/kubernetes.io~1ingress-class    # → kubernetes.io/ingress-class
  value: nginx

- op: add
  path: /spec/template/metadata/annotations/sidecar.istio.io~1inject
  value: "true"
```

#### Path resolution behavior

| Path type | Operation | Behavior |
|---|---|---|
| Map key | `add` | Auto-creates parent maps if missing |
| Map key | `replace` | Errors if the target doesn't exist |
| Map key | `remove` | Idempotent — succeeds silently if the key doesn't exist |
| Filter `[?(...)]` | any | Errors if no match |
| Array index | any | Errors on out-of-bounds |

#### `forEach` in patches

Apply the same operations once per item in a list:

```yaml
patches:
  - target:
      kind: Deployment
      group: apps
      version: v1
    forEach: ${parameters.envVars}
    var: envVar
    operations:
      - op: add
        path: /spec/template/spec/containers[?(@.name=='${parameters.containerName}')]/env/-
        value:
          name: ${envVar.name}
          value: ${envVar.value}
```

### Complete Trait example

```yaml
apiVersion: openchoreo.dev/v1alpha1
kind: Trait
metadata:
  name: persistent-volume
  namespace: default
spec:
  parameters:
    openAPIV3Schema:
      type: object
      properties:
        volumeName:
          type: string
        mountPath:
          type: string
        containerName:
          type: string
          default: main

  environmentConfigs:
    openAPIV3Schema:
      type: object
      properties:
        size:
          type: string
          default: "10Gi"
        storageClass:
          type: string
          default: "standard"

  validations:
    - rule: ${parameters.mountPath.startsWith("/")}
      message: "mountPath must be an absolute path"

  creates:
    - targetPlane: dataplane
      template:
        apiVersion: v1
        kind: PersistentVolumeClaim
        metadata:
          name: ${metadata.name}-${trait.instanceName}
          namespace: ${metadata.namespace}
        spec:
          accessModes: ["ReadWriteOnce"]
          storageClassName: ${environmentConfigs.storageClass}
          resources:
            requests:
              storage: ${environmentConfigs.size}

  patches:
    - target:
        kind: Deployment
        group: apps
        version: v1
      operations:
        - op: add
          path: /spec/template/spec/volumes/-
          value:
            name: ${parameters.volumeName}
            persistentVolumeClaim:
              claimName: ${metadata.name}-${trait.instanceName}

        - op: add
          path: /spec/template/spec/containers[?(@.name=='${parameters.containerName}')]/volumeMounts/-
          value:
            name: ${parameters.volumeName}
            mountPath: ${parameters.mountPath}
```

---

## 4. Schema syntax (`openAPIV3Schema`)

Both `parameters` and `environmentConfigs` use OpenAPI v3 JSON Schema under `openAPIV3Schema`. Same shape on ComponentType and Trait.

### Primitives

```yaml
openAPIV3Schema:
  type: object
  properties:
    name:
      type: string
    age:
      type: integer
      minimum: 0
      maximum: 120
    price:
      type: number
      minimum: 0.01
    enabled:
      type: boolean
      default: false
```

### Arrays

```yaml
properties:
  tags:
    type: array
    items:
      type: string

  ports:
    type: array
    items:
      type: integer

  mounts:
    type: array
    items:
      type: object
      properties:
        path:    { type: string }
        readOnly: { type: boolean }
```

### Maps (open-ended objects)

```yaml
properties:
  labels:
    type: object
    additionalProperties:
      type: string                  # map<string, string>
  ports:
    type: object
    additionalProperties:
      type: integer                 # map<string, int>
```

### Nested objects

```yaml
properties:
  database:
    type: object
    properties:
      host: { type: string }
      port:
        type: integer
        default: 5432
      options:
        type: object
        properties:
          ssl:     { type: boolean, default: true }
          timeout: { type: integer, default: 30 }
```

### Defaults — required-by-default rule

**All fields are required unless they have a `default`.** This applies to objects too.

```yaml
properties:
  # Required
  name:
    type: string

  # Optional with a primitive default
  replicas:
    type: integer
    default: 1

  # Optional empty list
  optionalTags:
    type: array
    items: { type: string }
    default: []

  # Optional empty map
  labels:
    type: object
    additionalProperties: { type: string }
    default: {}

  # Optional object — needs `default` at the object level even when all
  # nested fields have their own defaults.
  monitoring:
    type: object
    default: {}
    properties:
      enabled: { type: boolean, default: false }
      port:    { type: integer, default: 9090 }
```

When an object **isn't provided**, the object-level default is used and field-level defaults fill in missing keys. When the object **is provided**, the object-level default is ignored and field-level defaults still apply to omitted keys.

> **Why explicit object defaults**: this is intentional. Without them, adding a required field to an existing object silently breaks every Component already in the cluster. Forcing `default: {}` (or a meaningful default) makes object-optionality explicit and safe to evolve.

### Constraints

```yaml
properties:
  username:
    type: string
    minLength: 3
    maxLength: 20
    pattern: "^[a-z][a-z0-9_]*$"
  email:
    type: string
    format: email
  age:
    type: integer
    minimum: 0
    maximum: 150
  price:
    type: number
    minimum: 0
    exclusiveMinimum: true
    multipleOf: 0.01
  tags:
    type: array
    items: { type: string }
    minItems: 1
    maxItems: 10
    uniqueItems: true
```

### Enums

```yaml
properties:
  environment:
    type: string
    enum: [development, staging, production]
  logLevel:
    type: string
    enum: [debug, info, warning, error]
    default: info
```

### Documentation fields

```yaml
properties:
  apiKey:
    type: string
    title: "API Key"
    description: "Authentication key for external service"
    example: "sk-abc123"
```

### Custom annotations (`x-oc-*`)

Extension fields starting with `x-oc-` are ignored by validation but available to UI generators and tooling:

```yaml
properties:
  commitHash:
    type: string
    x-oc-build-inject: "git.sha"
    x-oc-ui-hidden: true
  advancedTimeout:
    type: string
    default: "30s"
    x-oc-scaffolding: "omit"
```

### Schema evolution

OpenChoreo schemas allow extra properties beyond what's defined. This makes promotion safe:

- Add fields to a Component before updating the ComponentType schema.
- Add new `environmentConfigs` in the target environment before promoting.
- Rolling back works — extra fields are ignored, not rejected.

---

## 5. Validation rules

`validations` is an array of `{rule, message}` entries. Each `rule` is a CEL expression that **must evaluate to true** for the resource to be accepted. Schema validation runs first, defaults are applied, then validation rules run with full context.

### Available context

- **ComponentType**: `metadata`, `parameters`, `environmentConfigs`, `workload`, `configurations`, `dependencies`, `dataplane`, `gateway`
- **Trait**: all of the above plus `trait.name` and `trait.instanceName`

### Examples

```yaml
validations:
  # Cross-field constraint
  - rule: ${parameters.environment != "production" || parameters.replicas >= 2}
    message: "Production requires at least 2 replicas"

  # Range bound
  - rule: ${!has(environmentConfigs.maxReplicas) || !has(environmentConfigs.minReplicas) || environmentConfigs.maxReplicas >= environmentConfigs.minReplicas}
    message: "maxReplicas must be >= minReplicas"

  # Workload check
  - rule: ${size(workload.endpoints) > 0}
    message: "Service components must expose at least one endpoint"

  # Environment-specific requirement
  - rule: ${metadata.environmentName != "production" || (has(environmentConfigs.resources) && has(environmentConfigs.resources.limits))}
    message: "Production deployments must specify resource limits"

  # Trait instance naming (DNS label)
  - rule: ${trait.instanceName.matches("^[a-z][a-z0-9-]*[a-z0-9]$")}
    message: "Trait instanceName must be a DNS-compliant label"

  # Mutually exclusive options
  - rule: ${[has(parameters.basicAuth), has(parameters.oauth)].filter(x, x).size() <= 1}
    message: "Cannot enable both basicAuth and oauth"

  # All-of in lists
  - rule: ${!has(parameters.databases) || parameters.databases.all(db, has(db.host) && has(db.port) && db.port > 0)}
    message: "All databases must have valid host and port"

  # Uniqueness
  - rule: ${!has(parameters.endpoints) || size(parameters.endpoints) == size(parameters.endpoints.map(ep, ep.name).distinct())}
    message: "Endpoint names must be unique"
```

### Error formatting

When a rule fails, the error names the failed expression and the message:

```text
rule[0] "${parameters.replicas >= 1}" evaluated to false: replicas must be at least 1
```

Multiple failures are joined with `;`.

### Writing good messages

- Bad: `"Invalid value"`
- Good: `"replicas must be between 1 and 20. Current value: ${parameters.replicas}"`
- Better: `"High availability mode requires >= 3 replicas. Set replicas >= 3 or disable highAvailability."`

Embed `${...}` expressions in the message string to surface the offending value.

---

## 6. How developers consume these

Developers reference a ComponentType from a `Component`, optionally attaching traits:

```yaml
apiVersion: openchoreo.dev/v1alpha1
kind: Component
metadata:
  name: my-api
  namespace: default
spec:
  componentType:
    kind: ClusterComponentType
    name: deployment/web-service
  parameters:
    port: 3000
    replicas: 2
  traits:
    - name: persistent-volume
      kind: ClusterTrait
      instanceName: data-storage      # unique on this component
      parameters:
        volumeName: data
        mountPath: /var/data
```

Per-environment overrides come from `ReleaseBinding`:

```yaml
apiVersion: openchoreo.dev/v1alpha1
kind: ReleaseBinding
metadata:
  name: my-api-production
spec:
  owner:
    projectName: my-project
    componentName: my-api
  environment: production
  releaseName: my-api-release-v1

  componentTypeEnvironmentConfigs:
    resources:
      cpu: "500m"
      memory: "1Gi"

  traitEnvironmentConfigs:
    data-storage:                     # keyed by trait instanceName
      size: "100Gi"
      storageClass: "production-ssd"
```

---

## 7. Common patterns

### Optional sidecar

Add a sidecar only when a parameter says so:

```yaml
patches:
  - target:
      kind: Deployment
      group: apps
      version: v1
      where: ${parameters.enableLogging}
    operations:
      - op: add
        path: /spec/template/spec/containers/-
        value:
          name: log-shipper
          image: ${parameters.logShipperImage}
          volumeMounts:
            - name: logs
              mountPath: /var/log

      - op: add
        path: /spec/template/spec/volumes/-
        value:
          name: logs
          emptyDir: {}

      - op: add
        path: /spec/template/spec/containers[?(@.name=='main')]/volumeMounts/-
        value:
          name: logs
          mountPath: /app/logs
```

### Per-endpoint resource generation (HTTPRoute fan-out)

```yaml
- id: httproute-internal
  forEach: |
    ${workload.endpoints
      .transformList(name, ep, ("internal" in ep.visibility) ? [name] : [])
      .flatten()}
  var: endpoint
  template:
    apiVersion: gateway.networking.k8s.io/v1
    kind: HTTPRoute
    metadata:
      name: ${oc_generate_name(metadata.componentName, endpoint, "internal")}
    spec:
      parentRefs:
        - name: ${gateway.ingress.internal.name}
          namespace: ${gateway.ingress.internal.namespace}
      rules:
        - backendRefs:
            - name: ${metadata.componentName}
              port: ${workload.endpoints[endpoint].port}
```

### ConfigMap per container

```yaml
- id: env-configs
  forEach: ${configurations.toConfigEnvsByContainer()}
  var: envConfig
  template:
    apiVersion: v1
    kind: ConfigMap
    metadata:
      name: ${envConfig.resourceName}
      namespace: ${metadata.namespace}
    data: |
      ${envConfig.envs.transformMapEntry(i, e, {e.name: e.value})}
```

### Conditional ExternalSecret for file mounts

```yaml
- id: secret-files
  forEach: ${configurations.toSecretFileList()}
  var: secret
  includeWhen: ${has(secret.remoteRef)}
  template:
    apiVersion: external-secrets.io/v1beta1
    kind: ExternalSecret
    metadata:
      name: ${secret.resourceName}
      namespace: ${metadata.namespace}
    spec:
      secretStoreRef:
        name: ${dataplane.secretStore}
        kind: ClusterSecretStore
      target:
        name: ${secret.resourceName}
      data:
        - secretKey: ${secret.name}
          remoteRef:
            key: ${secret.remoteRef.key}
            property: ${secret.remoteRef.property}
```

### Safe label addition (don't replace the whole map)

```yaml
# Good
- op: add
  path: /metadata/labels/monitoring
  value: enabled

# Bad — wipes all existing labels
- op: replace
  path: /metadata/labels
  value:
    monitoring: enabled
```

### Resource name uniqueness

For any resource generated in a `forEach` loop, name it with `oc_generate_name(...)` so collisions are impossible:

```yaml
metadata:
  name: ${oc_generate_name(metadata.componentName, item.name, "config")}
```

For trait-created resources, include `${trait.instanceName}` so multiple attachments of the same trait don't collide:

```yaml
metadata:
  name: ${metadata.name}-${trait.instanceName}
```

---

## 8. Verification

### MCP-first flow

All ComponentType / Trait tools take `scope` — `"cluster"` for the `Cluster*` variant, shown below.

```text
# Discover the creation schema, then create the type
get_component_type_creation_schema   scope: cluster   → schema for the spec body
create_component_type                scope: cluster   → name + spec (display_name / description optional)

# Confirm it's discoverable
list_component_types                 scope: cluster   → see the new type appear
get_component_type                   scope: cluster, name: <name>   → full resource (templates, allowed workflows, validation rules)

# For traits, same shape
get_trait_creation_schema            scope: cluster
create_trait                         scope: cluster   → name + spec
get_trait                            scope: cluster, name: <name>

# Test by creating a Component that uses it (paired with the developer skill, or direct via MCP)
create_component                                      → with this componentType
get_component <name>                                  → check status.conditions for validation failures
```

For an existing type, the update path is:

```text
get_component_type     scope: cluster, name: <name>   → fetch the current full spec
# modify locally
update_component_type  scope: cluster                 → name + the entire modified spec (full-replacement; missing fields are deleted)
```

### `kubectl apply -f` fallback

For large CEL templates or many-line edits, `kubectl apply -f` against a YAML file often leaves a cleaner diff than the MCP full-replacement update:

```bash
kubectl apply -f web-service.yaml
kubectl get clustercomponenttype                              # list
kubectl get clustercomponenttype deployment/web-service -o yaml
kubectl apply -f test-component.yaml
kubectl get component test-component -o yaml
```

For comparable inspection without leaving MCP, the equivalents are `list_component_types` / `get_component_type` (with `scope: "cluster"`) and `get_component <name>`. Both paths produce the same end state.

If a validation fails, `status.conditions` carries the rule index and message in the form documented in §5.

For the API CRD specs, see <https://openchoreo.dev/docs/reference/api/platform/>.
