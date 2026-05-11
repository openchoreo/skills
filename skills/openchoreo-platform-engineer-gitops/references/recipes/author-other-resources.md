# Recipe — ObservabilityAlertRule, NotificationChannel, and other PE resources via Git

Kinds without a dedicated recipe but following the same authoring pattern: template from a live `occ <kind> get`, or WebFetch the API ref from `llms.txt`. See [`../authoring.md`](../authoring.md) for the shape-lookup decision table.

## Quick reference

| Kind | API ref URL | Repo path |
| --- | --- | --- |
| `ObservabilityAlertRule` | `/docs/reference/api/platform/observabilityalertrule.md` | `namespaces/<ns>/platform/observability/alert-rules/<name>.yaml` |
| `ObservabilityAlertsNotificationChannel` | `/docs/reference/api/platform/observabilityalertsnotificationchannel.md` | `namespaces/<ns>/platform/observability/notification-channels/<name>.yaml` |

(`observability/` is a layout choice — not enforced by the controller. Pick a convention during scaffolding and stick to it.)

Cluster-scoped CRDs **must omit** `metadata.namespace`. Namespace-scoped CRDs **must include** it.

## ObservabilityAlertRule + NotificationChannel

Two resources that work together:

- **`ObservabilityAlertsNotificationChannel`** — where alerts go (Slack, PagerDuty, Email, webhook).
- **`ObservabilityAlertRule`** — when to alert (query against the observability plane, threshold, severity).

The `AlertRule` references one or more `NotificationChannel`s by name. Channel goes in first (Flux applies in dependency order regardless, but readers benefit).

```yaml
# notification-channel: slack-platform-alerts.yaml
apiVersion: openchoreo.dev/v1alpha1
kind: ObservabilityAlertsNotificationChannel
metadata:
  name: slack-platform-alerts
  namespace: default
spec:
  # …per API ref…

# alert-rule: high-error-rate.yaml
apiVersion: openchoreo.dev/v1alpha1
kind: ObservabilityAlertRule
metadata:
  name: high-error-rate
  namespace: default
spec:
  # …per API ref…
  notificationChannels:
    - name: slack-platform-alerts
```

The observability backend (Loki / Prometheus / Tempo / OpenSearch) must already be wired through the `ObservabilityPlane` CR — that's install-side, out of scope here.

## Steps

1. **Resolve the API ref URL** from `llms.txt` for the running `occ` minor.
2. **WebFetch the page**; read the `Spec Fields` table + sub-types + examples.
3. **Compose the YAML** at the documented repo path. Cite the page in a comment.
4. **Commit, PR, reconcile**:
   ```bash
   git checkout -b platform/<scope>-<name>-$(date +%Y%m%d-%H%M%S)
   git add <file>
   git commit -s -m "platform: add <Kind> <name>"
   git push origin HEAD
   gh pr create --fill
   ```
5. **Verify** — `occ <kind> get <name> [-n <ns>]`; `status.conditions[]` clean.

## Planes — out of scope by default

`DataPlane` / `ClusterDataPlane` / `WorkflowPlane` / `ClusterWorkflowPlane` / `ObservabilityPlane` / `ClusterObservabilityPlane` are one-time install-side setups with cert management, kubeconfig-shaped Secrets, gateway configuration, and observability adapter binding. This skill does not manage them in Git by default — they're tightly coupled with the control-plane install.

If the user *insists* on Git-managing a plane, expect significant out-of-band coordination:

- The plane CR references a `Secret` with kubeconfig data on the control-plane cluster. That Secret is operator-side; only the plane CR itself goes in Git.
- `Environment.spec.dataPlaneRef` is **immutable** — re-pointing requires delete + recreate of every dependent Environment.
- Plane health depends on cert validity, gateway routing, observability backend wiring.

Refer the user to <https://openchoreo.dev/docs/platform-engineer-guide/deployment-topology.mdx> for the install-side context. If they still want the CR in Git, author per the API ref (`/docs/reference/api/platform/dataplane.md` / `clusterdataplane.md` etc.) and place at `platform-shared/infra/{data,workflow,observability}-planes/<name>.yaml` (cluster) or `namespaces/<ns>/platform/infra/...` (namespace).

## Anti-patterns

- Forgetting to wire `notificationChannels[]` on an AlertRule — alerts fire but no one is paged.
- Hardcoding `metadata.namespace` on cluster-scoped CRDs — admission rejects.
- Managing planes in Git without coordinating the operator-side Secret + cert lifecycle.

## Related

- [`../authoring.md`](../authoring.md) — `llms.txt`, repo paths, git workflow
- [`scaffold.md`](./scaffold.md) — when migrating an existing cluster, alerts / channels often already exist and can be captured
- <https://openchoreo.dev/docs/platform-engineer-guide/deployment-topology.mdx> — plane install context
- <https://openchoreo.dev/docs/platform-engineer-guide/observability-alerting.mdx> — alerts and notification channels
