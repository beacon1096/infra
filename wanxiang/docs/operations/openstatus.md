# OpenStatus Operations

OpenStatus is the planned uptime/status monitoring service for `talos-ii`. It replaces the planned role of uptime-kuma; there is no uptime-kuma state to migrate.

## Deployment

- GitOps entry: `kubernetes/apps/monitoring/openstatus/ks.yaml`
- App manifests: `kubernetes/apps/monitoring/openstatus/app/`
- Namespace: `monitoring`
- Public status page: `https://status.beaco.works`
- Dashboard: `https://openstatus.beaco.works`

The Flux Kustomization reconciles normally once the manifests are committed and pushed.

## Runtime Shape

- `openstatus-libsql`: documented upstream datastore, persisted at `/var/lib/sqld` on Longhorn.
- `openstatus-tinybird`: local analytics/check-history service, persisted on Longhorn.
- `openstatus-workflows`: scheduler/background workflow service, persisted at `/app/data`.
- `openstatus-server`: API backend.
- `openstatus-dashboard`: admin UI.
- `openstatus-status-page`: public status-page renderer.
- `openstatus-checker`: stateless HTTP checker API; it does not schedule private-location checks.
- `openstatus-private-location`: ingest receiver. It reads monitor assignments from libSQL, accepts probe results, and writes them to Tinybird.
- `openstatus-probe-wanxiang`: active checker for the Wanxiang observation point. It fetches assigned monitors from the receiver and sends results back to it.

The stack is fixed to upstream revision `ef7691ad18971c14b9bd1a306b4bd0cf20b6e411`. The receiver uses the upstream image digest whose OCI revision label matches that commit. The active probe is built reproducibly by `packages/openstatus-private-probe` because upstream only published that component as a mutable `private-location:latest` image at this revision.

Do not substitute `openstatus-private-location` for `private-location`: despite the similar names, the first is the receiver and the second is the active probe. The probe's `OPENSTATUS_INGEST_URL` must point to `http://openstatus-private-location:8080`, not the API server on port 3000.

## Required Secrets

`kubernetes/apps/monitoring/openstatus/app/secret.sops.yaml` must stay SOPS-encrypted. Replace the placeholder GitHub OAuth values before unsuspending:

- `AUTH_GITHUB_ID`
- `AUTH_GITHUB_SECRET`

GitHub OAuth callback for the dashboard should be:

```text
https://openstatus.beaco.works/api/auth/callback/github
```

The private-location record must use the same `OPENSTATUS_KEY` as the probe and must be assigned at least one monitor. The receiver reads the Tinybird Local ingest credential as `TINYBIRD_TOKEN`; the manifest maps that variable from the existing encrypted `TINY_BIRD_API_KEY` key.

Before rollout, verify that the encrypted Tinybird value is the token returned by `tb --local info` for the deployed local workspace. A healthy receiver is not sufficient: `/health` only checks libSQL, and this fixed receiver can return HTTP 200 to a probe even when its Tinybird write failed.

The receiver and probe manifests intentionally remain at zero replicas until all rollout gates are satisfied:

1. Build and publish `openstatus-private-probe-oci`, then replace the probe tag with the registry digest.
2. Update the SOPS-encrypted Tinybird Local token through the approved secret-change path.
3. Run the receiver with the candidate token and require an ingest log with `tinybird.success=true`.
4. Change both replica counts to one in the reviewed rollout commit.

## Reconcile

```bash
KUBECONFIG=/home/beacon/swarm/kubeconfig kubectl -n monitoring get kustomization openstatus
```

If rollout must be paused, set `suspend: true` on the `openstatus` Flux Kustomization and let Flux reconcile.

## Smoke Tests

```bash
KUBECONFIG=/home/beacon/swarm/kubeconfig kubectl -n monitoring get pods,svc,httproute,pvc
curl -I https://openstatus.beaco.works/
curl -I https://status.beaco.works/
bash utils/check-openstatus-wiring.sh
```

Then verify in the UI:

- OAuth login succeeds.
- A workspace can be created.
- A basic HTTP monitor can be created.
- Restarting application pods does not lose workspace/monitor configuration.
- `openstatus-probe-wanxiang` logs `Started monitoring job` for an assigned monitor.
- The probe logs a successful check and the receiver logs the matching monitor, workspace, and region IDs with `tinybird.success=true`.
- The newest result appears in the dashboard with the Wanxiang private location and advances across at least two scheduled intervals.
- A controlled target failure changes the result to failed, and restoring the target produces a later successful result. Record the source, target, protocol, failure timestamp, and recovery timestamp in the issue.

`private_location.last_seen_at` is not proof of successful storage: this fixed receiver updates it even when Tinybird returns an error. Treat `tinybird.success=false`, a stale result, or a missing probe heartbeat as unknown/failed rather than healthy.

## MCP Integration

The fixed OpenStatus revision serves Streamable HTTP MCP from the API server.
Gateway routing exposes it at:

```text
https://openstatus.beaco.works/mcp
```

The pinned revision authenticates MCP with `x-openstatus-key`; it does not
implement the OAuth flow described by current upstream documentation. Create a
dedicated **Read-only** key in **Settings > General > API Keys**. A key's scope
is immutable, so revoke and replace it instead of widening it. Use Read & write
only for an explicitly approved incident/status-report automation workflow.

These credentials are not interchangeable:

- An MCP/API key starts with `os_` and belongs to one workspace.
- `OPENSTATUS_KEY` registers the private probe; it is not an MCP credential.
- `SUPER_ADMIN_TOKEN` is break-glass access, must start with `sa_` for this
  revision, and must not be configured in an assistant.

Keep the MCP key in the client's secret store or environment, never in Git.
Before supplying a key, an unauthenticated request should return API-server
`401` JSON. A `307` redirect to the dashboard login page means the Gateway is
still routing `/mcp` to the wrong backend.

```bash
curl -i -X POST https://openstatus.beaco.works/mcp \
  -H 'content-type: application/json' \
  -H 'accept: application/json, text/event-stream' \
  --data '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"smoke-test","version":"1.0"}}}'
```

After adding `x-openstatus-key` through the client's secret configuration,
verify `initialize`, `tools/list`, and `list_monitors`. For a Read-only key,
`tools/list` must omit `create_*`, `update_*`, `add_*`, and `resolve_*` tools.
Do not exercise a mutation merely to prove connectivity. If a later approved
workflow publishes a status report or maintenance, it must explicitly decide
the required `notify` value and resolve page/component IDs before mutation.

Current upstream also ships OAuth MCP and an official Kubernetes Helm chart,
but adopting them requires an application/database migration from this fixed
revision. Treat that as a separate reviewed upgrade; do not mix it into an MCP
reachability fix.

## Backup And Restore Gate

The three OpenStatus Longhorn volumes are selected by
`RecurringJob/daily-backup` through the `default` group. Selection, a
successful Kubernetes Job, and `BackupTarget/default` reporting available are
only prerequisites: the recurring-job controller can finish its Job while
individual volume backups fail.

Before a secret change, replica rollout, or upgrade, require a completed and
fresh backup for every volume:

```bash
MAX_BACKUP_AGE_HOURS=26 bash utils/check-openstatus-backups.sh
```

The check resolves each PVC to its Longhorn volume, verifies the `default`
group binding, and evaluates the newest `Backup` object's state, error, and
`snapshotCreatedAt`. Keep the per-volume table with the rollout evidence. A
stale or absent result is a failed recovery gate even when the top-level Job
succeeded.

The backups are crash-consistent and independent; they are not an atomic
snapshot across libSQL, Tinybird, and workflows. A safe restore drill therefore
uses new disposable volumes in an isolated namespace and never rebinds a
production PVC. Use the renderer rather than hand-writing `fromBackup` URLs:

```bash
export RUN_ID=20261015a
MAX_BACKUP_AGE_HOURS=26 \
  bash utils/render-openstatus-restore-drill.sh >"./openstatus-restore-${RUN_ID}.yaml"
kubectl apply --dry-run=client -f "./openstatus-restore-${RUN_ID}.yaml"
sha256sum "./openstatus-restore-${RUN_ID}.yaml"
```

The renderer is read-only. It stops unless every latest backup is clean,
completed, and fresh; the source volumes carry the `default` recurring-job
group; no run-id collision exists; all validation images resolve to running
digests; and Longhorn reports enough schedulable capacity. The drill restores
8 GiB libSQL, 10 GiB Tinybird, and 2 GiB workflows volumes with one replica:
20 GiB nominal and at least 24 GiB schedulable headroom including a 20% margin.
This is disposable recovery validation, not an HA copy.

The approval packet must contain:

- the renderer's backup/source-volume table and per-disk capacity table;
- the rendered manifest SHA-256 and its 20 GiB/24 GiB annotations;
- confirmation that no unrelated Longhorn or storage change is active;
- the exact `RUN_ID`, expected namespace/PV/Volume names, start window, and
  `cleanup-openstatus-restore-drill.sh --plan` output; and
- an explicit statement that no source Backup, source Volume, production PVC,
  Secret, or production Deployment is selected.

Applying the rendered manifest is a storage operation and requires approval.
After approval, apply that exact digest, wait for the inventory Job, and run:

```bash
kubectl apply -f "./openstatus-restore-${RUN_ID}.yaml"
RUN_ID="$RUN_ID" PHASE=storage bash utils/check-openstatus-restore-drill.sh
```

The namespace has default-deny ingress and egress. The initial Job mounts all
three restored PVCs read-only and refuses an empty/unreadable tree. The three
component deployments are rendered at zero replicas. Only after the storage
phase passes, scale the disposable libSQL, Tinybird, and workflows-reader
deployments to one; they use the exact source runtime digests. libSQL and
Tinybird may write only to the restored clones. The workflows image mounts its
clone read-only. No production Secret is mounted and no external egress exists.

```bash
kubectl -n "openstatus-restore-${RUN_ID}" scale deployment \
  restore-libsql restore-tinybird restore-workflows-reader --replicas=1
TINYBIRD_RESTORE_TOKEN='<from approved secret channel>' \
  RUN_ID="$RUN_ID" PHASE=data bash utils/check-openstatus-restore-drill.sh
```

The data phase performs a zero-write libSQL query and requires non-zero
workspace, monitor, private-location, and assignment rows. It also requires
non-zero `ping_response__v8` rows, intervals, monitors, and regions from the
restored Tinybird instance, plus workflows tree readability from the pinned
workflows image. `TINYBIRD_RESTORE_TOKEN` is supplied at execution time and is
never committed or printed.

Stop immediately on a stale/missing backup, capacity shortfall, concurrent
storage work, restore error, non-healthy volume, unexpected resource without
the exact run label, failed inventory, data-query error, empty expected data,
unexpected egress, or any observed production mutation. A successful mount
without the libSQL and Tinybird reads is not a successful drill.

Save the check output, then review the exact cleanup plan. Execution requires a
second run-id confirmation and selects exactly three labeled PVs, three labeled
Longhorn volumes, and the one labeled namespace:

```bash
RUN_ID="$RUN_ID" bash utils/cleanup-openstatus-restore-drill.sh --plan
CONFIRM_RUN_ID="$RUN_ID" RUN_ID="$RUN_ID" \
  bash utils/cleanup-openstatus-restore-drill.sh --execute
```

The static PVs use `Retain`; cleanup deletes the namespace first, then the
three recorded PVs and three restored Longhorn volumes. It refuses a missing or
mismatched label/count and never selects source backups or production storage.

Do not claim recovery readiness until all three volumes pass the freshness
check and at least libSQL plus Tinybird have completed this isolated read test.

## Replacement Acceptance

OpenStatus replaces the planned Uptime Kuma role only after all of the
following are evidenced together:

- a private probe produces stored results across at least two intervals;
- a controlled target failure and recovery are visible end to end;
- a published status page represents the monitored service;
- workspace, monitor, and recent-result persistence survive a controlled app
  restart;
- a dedicated Read-only MCP key completes the three checks above; and
- the libSQL and Tinybird backup/restore path has been verified.

Until then, OpenStatus is an evaluation deployment. It offers a substantially
better agent/API surface than Uptime Kuma, but its libSQL, Tinybird, workflows,
receiver, and probe topology has more operational failure modes than a single
Uptime Kuma service. Pod readiness, HTTP 200, private-location `last_seen_at`,
or a successful MCP handshake alone is not replacement evidence.

### Executable acceptance

Use a real site monitor for continuous-ingest evidence and a separate,
disposable canary monitor for the controlled failure. Do not interrupt a real
site to demonstrate failure. Creating/assigning monitors, changing the canary,
restarting the app, changing Secrets, and changing replica counts remain
separately reviewed production actions; the check itself is read-only.

After an approved test has produced at least two real-site intervals, record
the canary failure and recovery timestamps and the time immediately before the
controlled API-server restart. Then run:

```bash
TINYBIRD_READ_TOKEN='<from approved secret channel>' \
OBSERVATION_SINCE='2026-10-15T13:00:00Z' \
REAL_MONITOR_ID=101 REAL_REGION_ID=7 \
REAL_TARGET_URL='https://example-site.invalid/health' \
CANARY_MONITOR_ID=102 CANARY_REGION_ID=7 \
CANARY_TARGET_URL='https://dedicated-canary.invalid/health' \
FAILURE_AT='2026-10-15T13:10:00Z' \
RECOVERY_AT='2026-10-15T13:14:00Z' \
RESTART_AFTER='2026-10-15T13:15:00Z' \
STATUS_PAGE_URL='https://status.beaco.works/example' \
STATUS_PAGE_EXPECT='Example service' \
  bash utils/check-openstatus-acceptance.sh
```

The check requires one available digest-pinned receiver and probe; probe job
startup; sampled receiver `tinybird.success=true`; active libSQL assignments
and fresh heartbeats; stored real-site successes across at least two distinct
intervals; a canary success → error → later success sequence in Tinybird; an
API-server pod started after the declared restart boundary; and identifying
text on the public status page. Timestamps and IDs make reruns bounded and
prevent old results from satisfying a new exercise.

Finally, create a dedicated **Read-only** `os_` key through the approved secret
path and run the non-mutating MCP check:

```bash
OPENSTATUS_MCP_KEY='<read-only os_ key>' \
  bash utils/check-openstatus-mcp-readonly.sh
```

It requires an unauthenticated 401, then checks `initialize`, `tools/list`, and
`list_monitors`. Every advertised tool must carry `readOnlyHint: true`; any
`create_*`, `update_*`, `add_*`, or `resolve_*` tool fails the check. The key is
held in a mode-0600 temporary header file and is not printed.

Execution prerequisites still missing before the first production exercise
must be stated explicitly: merged public/private PRs, a published immutable
probe digest, the approved Tinybird Secret correction, a workspace and private
location with assigned real/canary monitors, a published status page, a
dedicated Tinybird read credential, a dedicated Read-only MCP key, fresh
per-volume backups, a successful isolated restore read, and approvals for the
Secret, storage, replica, canary-failure, and restart actions.

## Rollback

Revert the probe and receiver manifests through GitOps. Scaling down the probe stops new checks; scaling down the receiver also prevents probes from fetching monitor assignments and ingesting results. Reverting the `/mcp` path rule restores all requests on the dashboard hostname to the dashboard backend without touching application data. Revoke any test API key from the UI. Do not delete private-location rows, monitors, or PVCs as part of rollback.
