# CEL Reference (OpenChoreo Templates)

OpenChoreo's templating system embeds [CEL](https://github.com/google/cel-spec) expressions in YAML. Use this reference when authoring **ComponentType templates**, **Trait `creates` / `patches`**, and **Workflow `runTemplate` / `resources`**.

This file covers:

1. Expression syntax — `${...}` formats, resource-control fields
2. CEL language essentials (subset most used in templates)
3. OpenChoreo built-in functions (`oc_*`)
4. Context variables (what's available where)
5. Helper functions on `configurations`, `dependencies`, `workload`

For the full upstream reference: <https://openchoreo.dev/docs/reference/cel/>

---

## 1. Where CEL applies

| Surface | Field | Purpose |
|---|---|---|
| ComponentType | `resources[].template` | Generate Kubernetes resources |
| ComponentType | `resources[].includeWhen` | Conditional resource creation |
| ComponentType | `resources[].forEach` | Repeat a resource over a list/map |
| Trait | `creates[].template` | Generate new resources alongside the component |
| Trait | `creates[].includeWhen` | Conditional creates |
| Trait | `patches[].operations[].value` | Patch values (primitive, object, list) |
| Trait | `patches[].where` | Filter patch targets via CEL on `resource` |
| Workflow | `runTemplate` | Argo workflow spec with parameter substitution |
| Workflow | `resources[].template` | Auxiliary resources (ExternalSecret, etc.) |

---

## 2. Expression syntax

### Three formats

**Standalone value** — preserves the original type (int, map, list, bool):

```yaml
replicas: ${parameters.replicas}                # integer
labels:   ${metadata.labels}                    # map
enabled:  ${has(parameters.feature) ? parameters.feature : false}
```

**String interpolation** — embedded in a string, coerces to string:

```yaml
url:   "https://${metadata.name}.${metadata.namespace}.svc.cluster.local:${parameters.port}"
image: "${parameters.registry}/${parameters.repository}:${parameters.tag}"
```

**Dynamic map keys** — must evaluate to strings:

```yaml
labels:
  ${'app.kubernetes.io/' + metadata.name}: active
```

For complex expressions that span lines, use a YAML block scalar (`|`) to dodge quoting:

```yaml
nodeSelector: |
  ${parameters.highPerformance ? {"node-type": "compute"} : {"node-type": "standard"}}
```

### Resource control fields

**`includeWhen`** — entire field is a CEL expression; resource is created only when it evaluates to true:

```yaml
- id: hpa
  includeWhen: ${parameters.autoscaling.enabled}
  template: { ... }
```

**`forEach`** — iterate a list or map. `var: <name>` exposes each item as that variable:

```yaml
- id: db-config
  forEach: ${parameters.databases}
  var: db
  template:
    apiVersion: v1
    kind: ConfigMap
    metadata:
      name: ${oc_generate_name(metadata.name, db.name, "config")}
    data:
      host: ${db.host}
      port: ${string(db.port)}
```

When iterating a **map**, each item has `.key` and `.value`:

```yaml
forEach: ${parameters.configFiles}
var: config
template:
  metadata:
    name: ${oc_generate_name(metadata.name, config.key)}
  data:
    "${config.key}": ${config.value}
```

Map keys are iterated in **alphabetical order** for deterministic output.

**`includeWhen` is evaluated before `forEach`** and controls the entire block. The loop variable is **not available** inside `includeWhen` — for per-item filtering, use `.filter()` in the `forEach` expression itself:

```yaml
# WRONG — `integration` doesn't exist yet when includeWhen runs
- includeWhen: ${integration.enabled}
  forEach: ${parameters.integrations}
  var: integration

# RIGHT — filter inside the forEach
- forEach: ${parameters.integrations.filter(i, i.enabled)}
  var: integration
```

---

## 3. CEL language essentials

### Map and field access

```yaml
${parameters.replicas}                                # dot
${parameters["replicas"]}                             # bracket (equivalent for static)
${resource.metadata.labels["app.kubernetes.io/name"]} # required for keys with special chars
${parameters.?custom.?value.orValue("default")}       # optional chaining + default
```

### Conditionals

```yaml
${has(parameters.serviceType) ? parameters.serviceType : "ClusterIP"}
${parameters.replicas > 0 ? parameters.replicas : 1}
```

### List operations

```yaml
${parameters.envVars.map(e, {"name": e.key, "value": e.value})}     # map
${parameters.services.filter(s, s.enabled)}                          # filter
${parameters.items.join(",")}                                        # join
${parameters.names.sort()}                                           # sort
${parameters.items.sortBy(i, i.name)}                                # sortBy field
${parameters.list1 + parameters.list2}                               # concat
${[[1, 2], [3, 4]].flatten()}                                        # flatten → [1,2,3,4]
${parameters.items[0]}                                               # index
${size(parameters.items)}                                            # length
```

### Map operations

```yaml
${parameters.envVars.transformMapEntry(i, v, {v.name: v.value})}     # list → map
${parameters.labels.transformMap(k, v, {"app/" + k: v})}             # map → map
```

### String operations

```yaml
${metadata.name.upperAscii()}
${parameters.value.trim()}
${parameters.text.replace("old", "new")}
${parameters.value.startsWith("prefix")}
${parameters.path.split("/")}                  # split
${parameters.text.split(",", 2)}               # bounded split
${parameters.name.substring(0, 5)}             # substring
```

### Math

```yaml
${math.greatest([a, b, c])}
${math.least([a, b, c])}
${math.ceil(parameters.floatValue)}
```

### Encoding

```yaml
${base64.encode(bytes(parameters.value))}      # encode
${string(base64.decode(parameters.encoded))}   # decode
```

### Optional map keys

Use CEL's `?` prefix to make a map key conditional on the value's existence:

```yaml
container: |
  ${{
    "image": parameters.image,
    ?"cpu":    parameters.?cpu,
    ?"memory": parameters.?memory
  }}
```

---

## 4. OpenChoreo built-in functions

### `oc_omit()`

Removes a field or map key from the output. Two contexts:

**Field-level** — when used as a standalone value, removes the entire YAML key:

```yaml
metadata:
  name: ${metadata.name}
  annotations: ${has(parameters.annotations) ? parameters.annotations : oc_omit()}
  # If annotations is missing, the whole `annotations:` line is dropped
```

**Expression-level** — inside a CEL map literal, removes the key from the map:

```yaml
container: |
  ${{
    "image": parameters.image,
    "cpu":   parameters.cpuLimit > 0 ? parameters.cpuLimit : oc_omit(),
    "debug": parameters.environment == "dev" ? true : oc_omit()
  }}
```

> Prefer the optional-key syntax (`?"cpu": parameters.?cpu`) for simple existence checks. Use `oc_omit()` when conditional logic decides inclusion.

### `oc_merge(base, override, ...)`

Shallow-merge two or more maps. Later maps override earlier ones.

```yaml
labels: ${oc_merge({"app": metadata.name, "version": "v1"}, parameters.customLabels)}
config: ${oc_merge(defaults, layer1, layer2, layer3)}
```

Common pattern — merge platform labels with developer labels:

```yaml
labels: ${oc_merge(metadata.labels, parameters.customLabels)}
```

### `oc_generate_name(...args)`

Generates a Kubernetes-compliant resource name (lowercase, alphanumeric + hyphens, ≤63 chars) with a deterministic 8-char hash suffix.

```yaml
name: ${oc_generate_name(metadata.name, "config", parameters.environment)}
# → "myapp-config-prod-a1b2c3d4"

name: ${oc_generate_name("My_App", "Service!")}
# → "my-app-service-e5f6g7h8"
```

Use this for any resource generated in a `forEach` loop where collisions matter. The hash is deterministic, so re-runs produce the same name.

### `oc_dns_label(...args)`

Like `oc_generate_name`, but produces an RFC 1123 DNS label suitable for hostname **subdomains** (HTTPRoute hostnames):

```yaml
hostnames: |
  ${[gateway.ingress.external.?http, gateway.ingress.external.?https]
    .filter(g, g.hasValue()).map(g, g.value().host).distinct()
    .map(h, oc_dns_label(endpoint, metadata.componentName, metadata.environmentName, metadata.componentNamespace) + "." + h)}
# → "api-my-service-dev-default-a1b2c3d4.apps.example.com"
```

### `oc_hash(string)`

8-char FNV-32a hash of a string. Used internally by `oc_generate_name`; useful for volume name uniqueness:

```yaml
volumeName: main-file-mount-${oc_hash(config.mountPath + "/" + config.name)}
```

---

## 5. Context variables

Different surfaces expose different variables.

### Availability matrix

| Variable | Workflow | ComponentType | Trait `creates` | Trait `patches` |
|---|---|---|---|---|
| `metadata.*` | yes | yes | yes | yes |
| `parameters.*` | yes | yes | yes | yes |
| `environmentConfigs.*` | — | yes | yes | yes |
| `workload.*` | — | yes | — | — |
| `configurations.*` | — | yes | — | — |
| `dependencies.*` | — | yes | yes | yes |
| `dataplane.*` | — | yes | yes | yes |
| `gateway.*` | — | yes | yes | yes |
| `trait.*` | — | — | yes | yes |
| `externalRefs.*` | yes | — | — | — |
| `workflowplane.*` | yes | — | — | — |
| `resource` | — | — | — | yes (in `where`) |

### `metadata` (ComponentType / Trait)

| Field | Type | Description |
|---|---|---|
| `metadata.name` | string | Generated resource base name (e.g. `my-service-dev-a1b2c3d4`) |
| `metadata.namespace` | string | Target namespace for resources |
| `metadata.componentName` | string | Component name |
| `metadata.componentNamespace` | string | Component's namespace |
| `metadata.componentUID` | string | Component UID |
| `metadata.projectName` | string | Project name |
| `metadata.projectUID` | string | Project UID |
| `metadata.environmentName` | string | Environment name (`development`, `production`, …) |
| `metadata.environmentUID` | string | Environment UID |
| `metadata.dataPlaneName` / `dataPlaneUID` | string | Data plane identity |
| `metadata.labels` | map | Common labels for all generated resources |
| `metadata.annotations` | map | Common annotations |
| `metadata.podSelectors` | map | Platform-injected pod identity selectors |

### `parameters` and `environmentConfigs`

- **`parameters`** — values from `Component.spec.parameters` (or `traits[].parameters`) with schema defaults applied. **Static** across environments.
- **`environmentConfigs`** — values from `ReleaseBinding.spec.componentTypeEnvironmentConfigs` (or `traitEnvironmentConfigs[instanceName]`), pruned to the schema with defaults applied. **Per-environment**.

```yaml
replicas: ${environmentConfigs.replicas}
resources:
  limits:
    cpu: ${environmentConfigs.resources.cpu}
    memory: ${environmentConfigs.resources.memory}
```

### `workload` (ComponentType only)

| Field | Type | Description |
|---|---|---|
| `workload.container.image` | string | Container image |
| `workload.container.command` | []string | Command |
| `workload.container.args` | []string | Args |
| `workload.endpoints` | map[string]object | Endpoints, keyed by endpoint name |
| `workload.endpoints[name].type` | string | `HTTP` / `gRPC` / `GraphQL` / `Websocket` / `TCP` / `UDP` |
| `workload.endpoints[name].port` | int32 | Port |
| `workload.endpoints[name].targetPort` | int32 | Container port (defaults to `port`) |
| `workload.endpoints[name].basePath` | string | Optional base path |
| `workload.endpoints[name].visibility` | []string | `project` / `namespace` / `internal` / `external` |
| `workload.endpoints[name].schema` | object | Optional API schema |

### `configurations` (ComponentType only)

| Field | Type |
|---|---|
| `configurations.configs.envs` | []object — `{name, value}` |
| `configurations.configs.files` | []object — `{name, mountPath, value}` |
| `configurations.secrets.envs` | []object — `{name, value, remoteRef}` |
| `configurations.secrets.files` | []object — `{name, mountPath, remoteRef}` |

`remoteRef` has `key`, optional `property`, optional `version`.

### `dependencies` (ComponentType / Trait)

Resolved dependency env vars from the component's Workload `dependencies`.

| Field | Type | Description |
|---|---|---|
| `dependencies.items[]` | []object | Per-dependency entries with `namespace`, `project`, `component`, `endpoint`, `visibility`, `envVars` |
| `dependencies.envVars` | []object | Flat merged list — `{name, value}` |

The flat `envVars` list is the typical injection point:

```yaml
env: ${dependencies.toContainerEnvs()}    # macro — equivalent to dependencies.envVars
```

### `dataplane` (ComponentType / Trait)

| Field | Description |
|---|---|
| `dataplane.secretStore` | Name of the ClusterSecretStore (use in `ExternalSecret.spec.secretStoreRef.name`) |

### `gateway` (ComponentType / Trait)

| Field | Description |
|---|---|
| `gateway.ingress.external.name` / `.namespace` | External gateway resource identity |
| `gateway.ingress.external.http` / `.https` | Optional listener config — has `.host` |
| `gateway.ingress.internal.name` / `.namespace` / `.http` / `.https` | Same for the internal gateway |

```yaml
parentRefs:
  - name: ${gateway.ingress.external.name}
    namespace: ${gateway.ingress.external.namespace}
```

### `trait` (Trait only)

| Field | Description |
|---|---|
| `trait.name` | Trait name (e.g. `persistent-volume`) |
| `trait.instanceName` | Per-component instance name (must be unique on the component) |

### Workflow-only variables

| Variable | Description |
|---|---|
| `metadata.workflowRunName` | WorkflowRun CR name |
| `metadata.namespaceName` | WorkflowRun namespace |
| `metadata.namespace` | Enforced workflow plane namespace (e.g. `workflows-default`) |
| `metadata.labels` | WorkflowRun labels (`openchoreo.dev/component`, `openchoreo.dev/project`) |
| `parameters.*` | From `WorkflowRun.spec.workflow.parameters`, schema defaults applied |
| `workflowplane.secretStore` | ClusterSecretStore from the referenced WorkflowPlane |
| `externalRefs[id]` | Resolved external CR specs, keyed by `Workflow.spec.externalRefs[].id` |

---

## 6. Helper functions

These are CEL macros / extension methods that collapse common patterns. Prefer them over hand-rolled equivalents.

### `configurations.toContainerEnvFrom()`

Builds the `envFrom` array for a container — generates `configMapRef` and `secretRef` entries from `configurations.configs.envs` and `configurations.secrets.envs`:

```yaml
containers:
  - name: main
    image: ${workload.container.image}
    envFrom: ${configurations.toContainerEnvFrom()}
```

### `configurations.toConfigEnvsByContainer()` / `toSecretEnvsByContainer()`

Returns one entry per container that has config envs (resp. secret envs), each with `container`, `resourceName`, and `envs`. Use in `forEach` to create one ConfigMap (or ExternalSecret) per container:

```yaml
- id: env-config
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

### `configurations.toConfigFileList()` / `toSecretFileList()`

Flattens config (or secret) files from all containers into a single list. Each item has `name`, `mountPath`, `value`, `resourceName`, and (for secrets) `remoteRef`:

```yaml
- id: config-files
  forEach: ${configurations.toConfigFileList()}
  var: config
  template:
    apiVersion: v1
    kind: ConfigMap
    metadata:
      name: ${config.resourceName}
    data:
      ${config.name}: |
        ${config.value}

- id: secret-files
  forEach: ${configurations.toSecretFileList().filter(s, has(s.remoteRef))}
  var: secret
  template:
    apiVersion: external-secrets.io/v1beta1
    kind: ExternalSecret
    metadata:
      name: ${secret.resourceName}
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

### `configurations.toContainerVolumeMounts()` / `configurations.toVolumes()`

Build `volumeMounts` and `volumes` arrays for config and secret files. Volume names use `oc_hash(mountPath + "/" + name)` for collision avoidance:

```yaml
containers:
  - name: main
    volumeMounts: ${configurations.toContainerVolumeMounts()}
volumes: ${configurations.toVolumes()}
```

### `dependencies.toContainerEnvs()`

Macro returning the flat env-var list. Equivalent to `dependencies.envVars`:

```yaml
env: ${dependencies.toContainerEnvs()}
```

### `workload.toServicePorts()`

Converts `workload.endpoints` to Kubernetes Service `ports[]` — handles port name DNS-compliance (via `oc_dns_label`), `targetPort` defaulting, and protocol mapping (`UDP` endpoints → `UDP`, others → `TCP`):

```yaml
- id: service
  template:
    apiVersion: v1
    kind: Service
    metadata:
      name: ${metadata.componentName}
    spec:
      selector: ${metadata.podSelectors}
      ports: ${workload.toServicePorts()}
```

> For HTTPRoute backend refs, use `workload.endpoints[name].port` directly — `toServicePorts()` is for `Service` resources only.

---

## 7. End-to-end pattern

ComponentType template that uses metadata, parameters, environmentConfigs, workload, configurations, and dependencies in idiomatic form:

```yaml
spec:
  workloadType: deployment
  resources:
    - id: deployment
      template:
        apiVersion: apps/v1
        kind: Deployment
        metadata:
          name: ${metadata.name}
          namespace: ${metadata.namespace}
          labels: ${oc_merge(metadata.labels, parameters.customLabels)}
        spec:
          replicas: ${environmentConfigs.replicas}
          selector:
            matchLabels: ${metadata.podSelectors}
          template:
            metadata:
              labels: ${oc_merge(metadata.labels, metadata.podSelectors)}
            spec:
              containers:
                - name: main
                  image: ${workload.container.image}
                  ports:
                    - containerPort: ${parameters.port}
                  env: ${dependencies.toContainerEnvs()}
                  envFrom: ${configurations.toContainerEnvFrom()}
                  volumeMounts: ${configurations.toContainerVolumeMounts()}
                  resources:
                    limits:
                      cpu: ${has(environmentConfigs.cpuLimit) ? environmentConfigs.cpuLimit : oc_omit()}
                      memory: ${environmentConfigs.memoryLimit}
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

For more worked examples — including secrets, file mounts, HTTPRoute generation per endpoint, and the full helper-function expansion — see <https://openchoreo.dev/docs/reference/cel/>.
