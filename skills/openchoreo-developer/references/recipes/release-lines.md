# Release lines

Run more than one version of a Component side by side in the same environments, for example a `next` line built from another branch next to the stable build. Each line is built, released, promoted, rolled back and deleted on its own. **v1.4+ only.** The tools below exist when the MCP server lists `list_release_lines`. Without that tool there are no lines, so use a second Component instead and tell the user why.

## How a line relates to its Component

```text
Component (its own config = the implicit "main" line)
  ├── <component>-workload → releases → one ReleaseBinding per env        (main line)
  └── ReleaseLine "next" (overrides on top of the Component)
        └── <component>-next-<hash>-workload → releases → one ReleaseBinding per env
```

- **The Component is the `main` line.** Nothing about it changes when lines are added. Its Workload, releases and bindings keep their names.
- **A line inherits the Component's spec, plus its own overrides:**
  - `parameters` and `workflow_parameters` are deep-merged. Maps merge key by key; scalars and lists replace.
  - `traits` are merged by kind + name + `instanceName`. A matching trait gets its parameters deep-merged; a new one is appended.
  - `auto_deploy` replaces the Component's value.
  - The ComponentType and the workflow kind/name are shared by every line.
- **A line has its own Workload.** It does not inherit the main line's. Env vars, endpoints and dependencies set on `<component>-workload` reach the main line only.
- **Line objects are named `{component}-{line}-{hash}-…`.** Read the actual names from `get_release_line` (`environments[]`, `latestRelease`) or from the `releaseLine` field in list output. Don't compose them.
- **A line has its own URLs.** Its routes are named from `{component}-{line}-{hash}`. Read them from the line's binding `status.endpoints[]`.

## Recipe — add a line

```yaml
create_release_line
  namespace_name: default
  component_name: greeter
  name: greeter-next                     # unique in the namespace, across ALL components
  description: "Preview line, built from the release-next branch"
  workflow_parameters:                   # source-build: build another branch
    repository:
      revision:
        branch: release-next
  traits:                                # optional: overrides only this line
    - kind: ClusterTrait
      name: health-probes
      instanceName: health
      parameters: { readiness: { enabled: true } }
```

The line name is a namespace-wide object name, so two components can't both have a line called `next`. Prefix it with the component (`greeter-next`) unless the user picked a name. `main` and `default` are reserved. Names are lowercase DNS labels of at most 63 characters.

## Recipe — give the line a build

**Source-build component** (Component has `spec.workflow`): build the line. The run merges the line's `workflow_parameters` onto the component's, and writes the line's Workload from that branch's `workload.yaml`. This needs a CI Workflow that forwards the release line. The default Workflows and ComponentTypes are applied at install time, not upgraded with the Helm chart, so a cluster upgraded to v1.4 may still run pre-1.4 ones. After the first line build, check `list_workloads`. If no Workload with `releaseLine` appeared and the main line's Workload changed instead, stop and escalate to the platform engineer.

```yaml
trigger_workflow_run
  namespace_name: default
  project_name: default
  component_name: greeter
  release_line: greeter-next
```

When the Component has `autoBuild` on, a Git push to the line's branch rebuilds the line too. A line pinned to a `commit` isn't moved by pushes. Follow the run as in [`build-from-source.md`](build-from-source.md).

**BYO image** (no `spec.workflow`): create the line's Workload yourself, with the line's image:

```yaml
create_workload
  namespace_name: default
  component_name: greeter
  release_line: greeter-next
  workload_spec: { container: { image: "ghcr.io/acme/greeter:2.0.0-rc1" }, endpoints: { ... } }
```

Later image bumps go through `update_workload` on the line's Workload name. Find it with `list_workloads`, which shows `releaseLine`.

## Recipe — deploy and promote a line

With `auto_deploy` (the Component's, or the line's override), a new release of the line is cut and bound to the **first** environment of the pipeline whenever what the line renders changes: its Workload, its `parameters` / `traits` overrides, or the ComponentType or Traits. A change to `workflow_parameters` or `auto_deploy` alone cuts nothing until the next build changes the Workload. Without it, cut releases with `create_component_release` (`release_line` set). That tool is in the PE toolset; if it isn't exposed, set `auto_deploy: true` on the line. To go further down the pipeline, bind a release of the line with `release_line` set:

```yaml
create_release_binding
  namespace_name: default
  project_name: default
  component_name: greeter
  release_line: greeter-next
  environment: staging
  release_name: <the release the line runs in development>   # get_release_line → environments[]
```

The rules match the main line's, applied per line:

- One binding per line per environment.
- Promotion follows the pipeline. A release reaches an environment only while the same line runs it in the source environment.
- The release must belong to the line. Binding another line's release fails.
- Per-environment overrides go on the line's binding. See [`override-per-environment.md`](override-per-environment.md).

Change an existing line binding with `update_release_binding` and its binding name. The other lines are never touched.

### Verify

```yaml
get_release_line
  namespace_name: default
  component_name: greeter
  release_line_name: greeter-next
```

`environments[]` lists each environment's binding, release and `ready`. Then call `get_release_binding` on that binding and read `status.conditions[]` and `status.endpoints[]`, as for any binding. `list_release_lines` shows `main` first, then every line, with their environments.

## Variant — roll a line back

Point the line's binding at an earlier release of the **same line** (`list_component_releases` shows `releaseLine` per release). Roll back in pipeline order, first environment first, because each environment only accepts what the previous one runs.

With `auto_deploy` on, the line soon binds its latest release to the first environment again. To keep a rollback, turn it off for this line first, and restore it once a fixed build is ready:

```yaml
patch_release_line
  namespace_name: default
  component_name: greeter
  release_line_name: greeter-next
  auto_deploy: false
# later: patch_release_line ... reset: [auto_deploy]   → inherit the component's value again
```

## Variant — change a line's overrides

`patch_release_line` updates only the fields you pass. A passed `parameters`, `traits` or `workflow_parameters` **replaces** the line's whole override for that field, so read the line first and send the full value. `reset: [parameters | traits | workflow_parameters | auto_deploy]` drops an override so the line inherits the Component's value again. With `auto_deploy`, a changed `parameters` or `traits` override cuts a new release of the line and deploys it to the first environment. A `workflow_parameters` change takes effect at the line's next build.

## Variant — depend on a specific line

A consumer's `dependencies.endpoints[]` entry targets the provider's **main line** unless it names `releaseLine`. It never follows the consumer's own line. See [`connect-components.md`](connect-components.md) → *Target a release line*.

## Variant — delete a line

```yaml
delete_release_line
  namespace_name: default
  component_name: greeter
  release_line_name: greeter-next
```

This undeploys the line from every environment and removes its releases and Workload. The main line and other lines keep running. It's destructive, so confirm with the user first. To take a line offline in one environment only, set `release_state: Undeploy` on its binding instead.

## Gotchas

- **A line's binding fails with `ReleaseLineNameCollision` or `ReleaseLinePodLabelOverlap`.** The ComponentType or one of its Traits isn't release-line-safe: it names objects from the component name alone, or puts `metadata.labels` on pods. Nothing is wrong with the line. Escalate to the platform engineer (PE skill: *Release-line-safe names and pod labels*). The v1.4 default types are safe, but a cluster upgraded from an earlier version keeps the types it was installed with until the PE re-applies them.
- **`ReleaseLineNotFound`** on a binding means the line doesn't exist in the namespace. A line that exists but belongs to another component reports `InvalidReleaseConfiguration` instead.
- **Line names are namespace-wide.** Creating `next` for a second component fails, because the first component's line already holds the name.
- **Main-line Workload edits don't reach a line.** Repeat them on the line's Workload. For a source-built line, put them in that branch's `workload.yaml`, because each build replaces the line's Workload from it.
- **In tool arguments, `release_line: main` (or omitting it) means the Component itself.** In resource fields, such as `releaseLine` on a Workload dependency, omit it for the main line: the API rejects `main` there.

## Related recipes

- [`deploy-and-promote.md`](deploy-and-promote.md) — the same binding mechanics on the main line
- [`build-from-source.md`](build-from-source.md) — following a build run
- [`connect-components.md`](connect-components.md) — consuming a specific line
- [`inspect-and-debug.md`](inspect-and-debug.md) — a line's binding that won't go Ready
