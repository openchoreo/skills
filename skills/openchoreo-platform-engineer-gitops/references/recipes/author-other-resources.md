# Recipe — ObservabilityAlertRule, NotificationChannel, and other PE resources via Git

Kinds without a dedicated recipe; same pattern. Use `./scripts/fetch-page.sh --exact --title "<Kind>"` for the full schema. See [`../authoring.md`](../authoring.md) for the shape-lookup decision table.

## Quick reference

| Kind | Repo path |
| --- | --- |
| `ObservabilityAlertRule` | `namespaces/<ns>/platform/observability/alert-rules/<name>.yaml` |
| `ObservabilityAlertsNotificationChannel` | `namespaces/<ns>/platform/observability/notification-channels/<name>.yaml` |

`observability/` is a layout convention — not enforced by the controller. Pick during scaffolding and stick to it.

Cluster-scoped CRDs **omit** `metadata.namespace`; namespace-scoped CRDs **include** it.

## ObservabilityAlertRule + NotificationChannel

Two resources that work together:

- **`NotificationChannel`** — where alerts go (Slack, PagerDuty, Email, webhook).
- **`AlertRule`** — when to alert (query against the observability plane, threshold, severity); references one or more channels by name.

```yaml
apiVersion: openchoreo.dev/v1alpha1
kind: ObservabilityAlertsNotificationChannel
metadata:
  name: slack-platform-alerts
  namespace: default
spec:
  # …per fetch-page.sh --title "ObservabilityAlertsNotificationChannel"…

---
apiVersion: openchoreo.dev/v1alpha1
kind: ObservabilityAlertRule
metadata:
  name: high-error-rate
  namespace: default
spec:
  # …per fetch-page.sh --title "ObservabilityAlertRule"…
  notificationChannels:
    - name: slack-platform-alerts
```

The observability backend (Loki / Prometheus / Tempo / OpenSearch) must already be wired via the `ObservabilityPlane` CR — install-side, out of scope.

## Steps

1. `./scripts/fetch-page.sh --exact --title "<Kind>"` for the full schema.
2. Compose at the path from the table above.
3. Commit + PR — branch `platform/<scope>-<name>-<ts>`, message `"platform: add <Kind> <name>"`. Canonical flow in [`../authoring.md`](../authoring.md) *Git workflow*.
4. Verify: `occ <kind> get <name> [-n <ns>]`; `status.conditions[]` clean.

## Planes — out of scope by default

`DataPlane` / `ClusterDataPlane` / `WorkflowPlane` / `ClusterWorkflowPlane` / `ObservabilityPlane` / `ClusterObservabilityPlane` are install-side: cert management, kubeconfig Secrets, gateway / observability adapter binding. Not managed in Git by default.

If the user insists, two coupling costs to surface:

- The plane CR references a `Secret` with kubeconfig data on the control-plane cluster. That Secret is operator-side; only the plane CR goes in Git.
- `Environment.spec.dataPlaneRef` is immutable — re-pointing requires delete + recreate of every dependent Environment + ReleaseBinding.

Author per `./scripts/fetch-page.sh --exact --title "<PlaneKind>"`; place at `platform-shared/infra/{data,workflow,observability}-planes/<name>.yaml` (cluster) or `namespaces/<ns>/platform/infra/...` (namespace).

## Anti-patterns

- Forgetting `notificationChannels[]` on an AlertRule — alerts fire but no one is paged.
- Hardcoding `metadata.namespace` on cluster-scoped CRDs — admission rejects.
- Managing planes in Git without coordinating the operator-side Secret + cert lifecycle.
