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
production PVC.

The fixed upstream revision contains
`packages/tinybird/datasources/ping_response__v8.datasource`, with
`monitorId`, `region`, `cronTimestamp`, and `requestStatus`. Its byte-identical
copy is kept at
`kubernetes/apps/monitoring/openstatus/bootstrap/tinybird/ping_response__v8.datasource`
with SHA-256
`ebee697a5b25d3808d2e931d3b0ef77ef2d666e273931099ecabffcf96e96207`.
The validated Tinybird Local runtime digest is
`sha256:107829e9143df641e81c7339b0fd7bf9ed97bcea8841f1bb7e9b2fc966049b20`;
its embedded CLI prints only a placeholder version and is not accepted as a
version pin. This preparation change deliberately leaves the live Deployment
on its existing tag: adding the digest changes the Pod template and the
`Recreate` Deployment would restart. The exact inactive JSON patch is staged
as `app/tinybird-runtime-pin.patch.json` for a separately approved runtime
commit after the pre-initialization backup.

First classify the workspace without mutation:

```bash
bash utils/initialize-openstatus-tinybird.sh --plan
TINYBIRD_READ_TOKEN='<DATASOURCES:READ:ping_response__v8 token>' \
  bash utils/initialize-openstatus-tinybird.sh --check
```

The check returns `initialized-empty` or `ingested` with exit 0,
`authentication-failed` with exit 3, `uninitialized` with exit 4, and an
unclassified query failure with exit 1. Never treat authentication failure as
an absent datasource. Initialization requires two ephemeral credentials from
the approved channel: `DATASOURCES:CREATE` and a separate
`DATASOURCES:READ:ping_response__v8`; neither belongs in a Kubernetes Secret or
Git. The command below remains blocked until the pre-initialization backup
succeeds and a separately reviewed GitOps commit adds
`tinybird-runtime-pin.patch.json` to `app/kustomization.yaml`. Reconcile that
commit and verify both the Deployment image and running `imageID` end in the
required digest before supplying these exact stage-2 payload settings:

```bash
export BASELINE_PURPOSE=post-init
export INITIALIZE_TINYBIRD=execute
export CONFIRM_TINYBIRD_INITIALIZE=ping_response__v8@ef7691ad
# Supply TINYBIRD_CREATE_TOKEN and TINYBIRD_READ_TOKEN only to the bounded
# with-openstatus-quiesced.sh invocation documented below.
```

The pin commit is an intentional `Recreate` rollout and is not part of this
preparation PR. The initializer creates only an absent `ping_response__v8`,
refuses populated or ambiguous states, and verifies `initialized-empty`. On a transport/API failure, resume
writers first and rerun `--check`: `uninitialized` may be resubmitted only with
approval, `initialized-empty` is an idempotent success, and `ingested` or an
authentication failure is a hard stop. Do not delete a partially observed
datasource as an automatic rollback; the pre-initialization backup is the
recovery point.

### Exact three-volume baseline backup

Never clone `CronJob/daily-backup`: it selects the Longhorn `default` group,
currently 51 volumes. Each baseline run instead renders a temporary
`backup-force-create` RecurringJob with `groups: []` and binds its direct label
to exactly these current PVC→PV→Volume mappings:

- `openstatus-libsql-data` (8 GiB)
- `openstatus-tinybird-data` (10 GiB)
- `openstatus-workflows-data` (2 GiB)

The validator resolves the mappings at every phase and rejects a fourth label,
a changed binding, an unhealthy/detached volume, or a manifest with a group.
Prepare the original writer replicas and Flux revision before approval:

```bash
export RUN_ID=20261015-preinit
export REPLICA_STATE_FILE="./openstatus-replicas-${RUN_ID}.json"
bash utils/quiesce-openstatus-writers.sh --plan >"$REPLICA_STATE_FILE"
export EXPECTED_REPLICA_STATE_SHA256="$(sha256sum "$REPLICA_STATE_FILE" | awk '{print $1}')"
```

The six writers are `openstatus-server`, `openstatus-dashboard`,
`openstatus-workflows`, `openstatus-checker`, `openstatus-private-location`,
and `openstatus-probe-wanxiang`. The dashboard is included because the fixed
revision's tRPC monitor service writes directly to libSQL. libSQL and Tinybird
remain available. Because the cluster setting
`allow-recurring-job-while-volume-detached` is `false`, the plan also pins the
running workflows image digest and names one temporary holder Pod. The stop
phase mounts only `openstatus-workflows-data` read-only in that Pod; its command
is `sleep 900`, so it cannot extend attachment indefinitely.

After approval, use the wrapper below rather than calling `--stop` directly.
It installs recovery handling and starts one 600-second deadline before the
first mutation. It suspends only Flux `Kustomization/monitoring/openstatus`,
stops all six Deployments, proves every selected writer Pod exited, creates the
reviewed holder, captures the baseline and starts only the exact three-volume
backup. A pre-initialization run must classify `uninitialized`; a later run
must classify `initialized-empty` or `ingested`:

```bash
export BASELINE_FILE="./openstatus-baseline-${RUN_ID}.json"
export BACKUP_MANIFEST="./openstatus-backup-${RUN_ID}.yaml"
export BACKUP_SCOPE_FILE="./openstatus-backup-scope-${RUN_ID}.json"
export BASELINE_PURPOSE=pre-init
TINYBIRD_READ_TOKEN='<from approved secret channel>' \
REPLICA_STATE_FILE="$REPLICA_STATE_FILE" \
EXPECTED_REPLICA_STATE_SHA256="$EXPECTED_REPLICA_STATE_SHA256" \
  bash utils/with-openstatus-quiesced.sh -- \
    bash utils/start-openstatus-baseline-backup.sh
```

`with-openstatus-quiesced.sh` owns the EXIT/INT/TERM recovery trap from before
the first mutation. Its child and every blocking `kubectl` call are limited by
the same absolute deadline. Baseline failure, manifest or Job creation
failure, timeout, or interruption therefore enters replica and Flux recovery.
Resume preserves an unexpected holder but still attempts every recorded
replica restore and `suspend=false`; it exits non-zero so the unknown object is
investigated rather than deleted.

The wrapper also creates
`${REPLICA_STATE_FILE}.quiesce-ownership.json`. Absence means the helper has
not passed its read-only Flux/revision, replica, image and holder preflight;
`acquired` is written atomically after those checks and before the first API
mutation; `recovered` is written only after the recorded replicas, holder and
Flux state have been restored. A preflight refusal therefore performs no
cluster writes, while an API mutation that applies but reports failure is still
covered by the already-installed outer trap. The wrapper makes only one
recovery call; the helper owns an interrupted recovery retry, and first checks
whether recovery is already complete to avoid replaying an old plan. Preserve
an `acquired` marker and its exact replica-state file for incident recovery;
never replace it with a new plan or remove it until the original state is
verified. A completed or refused run needs a new plan before another window.

The payload writes the baseline, manifest and authoritative scope file,
re-resolves all three PVC→PV→Volume bindings, applies only the temporary
`groups: []` RecurringJob and its three direct labels, and starts only the
generated CronJob. It returns after exactly three new snapshots and their
Backup CRs are registered without errors. The wrapper then restores writers
and Flux immediately. Backup upload continues afterward, so no 51-volume
operation can extend the stop-write window. Verify completion separately:

```bash
export JOB_NAME="osb-${RUN_ID}"
export EXPECTED_SCOPE_SHA256="$(jq -r .scope_sha256 "$BACKUP_SCOPE_FILE")"
timeout --foreground --kill-after=5s 2h \
  kubectl -n storage wait --for=condition=complete "job/${JOB_NAME}" --timeout=2h
RUN_ID="$RUN_ID" BACKUP_MANIFEST="$BACKUP_MANIFEST" BASELINE_FILE="$BASELINE_FILE" \
EXPECTED_SCOPE_SHA256="$EXPECTED_SCOPE_SHA256" \
  bash utils/check-openstatus-baseline-backup.sh backups
```

A Job success is still not backup success; only the last check proves three
completed, error-free, baseline-linked backups. Review cleanup before removing
only the three direct labels and temporary Job/CronJob/RecurringJob. Preserve
the three Snapshot and Backup objects as the recovery point:

```bash
RUN_ID="$RUN_ID" BACKUP_MANIFEST="$BACKUP_MANIFEST" \
EXPECTED_SCOPE_SHA256="$EXPECTED_SCOPE_SHA256" \
  bash utils/check-openstatus-baseline-backup.sh cleanup-plan

jq -r '.bindings[].volume' "$BACKUP_SCOPE_FILE" |
  while read -r volume; do
    kubectl -n storage label volumes.longhorn.io "$volume" \
      "recurring-job.longhorn.io/${JOB_NAME}-" --overwrite
  done
kubectl -n storage delete job "$JOB_NAME" --ignore-not-found --wait=true
kubectl -n storage delete recurringjob.longhorn.io "$JOB_NAME" \
  --ignore-not-found --wait=true
kubectl -n storage delete cronjob "$JOB_NAME" --ignore-not-found --wait=true
```

If creation fails partway, resume writers and Flux first. The same cleanup plan
accepts any subset of the three expected direct labels but refuses an extra
selection; remove only names printed by the plan after investigation.

Run this procedure twice: first with `BASELINE_PURPOSE=pre-init` to protect the
uninitialized source, then—after the separately approved digest rollout—with
`BASELINE_PURPOSE=post-init` to initialize and create an `initialized-empty`
baseline and recovery point in the same bounded maintenance session. Later
ingest recovery requires a third, new `ingested` baseline and new backups.

For stage 2, generate a fresh replica plan and fresh output paths, set the
three exported initialization values shown above, and invoke the same wrapper
with both ephemeral tokens on its environment:

```bash
TINYBIRD_CREATE_TOKEN='<DATASOURCES:CREATE token>' \
TINYBIRD_READ_TOKEN='<DATASOURCES:READ:ping_response__v8 token>' \
REPLICA_STATE_FILE="$REPLICA_STATE_FILE" \
EXPECTED_REPLICA_STATE_SHA256="$EXPECTED_REPLICA_STATE_SHA256" \
  bash utils/with-openstatus-quiesced.sh -- \
    bash utils/start-openstatus-baseline-backup.sh
```

The payload invokes `initialize-openstatus-tinybird.sh --execute` only after
all six writer Pods have exited, then captures the `initialized-empty` baseline
and starts the linked three-volume backup before the same deadline. Any
initialization error enters the same replica and Flux recovery path.

Submit approvals in three bounded stages, not as a general storage or rollout
approval:

1. **Pre-initialization protection:** exact `RUN_ID`, replica-state SHA-256,
   Flux revision, three binding rows and scope SHA-256, expected
   `uninitialized` baseline, 600-second stop-write limit, exact read-only holder
   name/image/PVC plus its 900-second self-stop, temporary storage resource
   names, and the cleanup plan.
2. **Pin, initialize and protect the empty datasource:** datasource SHA-256,
   inactive runtime-patch SHA-256, required Tinybird image digest, explicit
   approval for the `Recreate` rollout after stage 1, the two token scopes,
   exact confirmation string and refusal/failure handling, then a new
   `initialized-empty` baseline and three-volume scope/cleanup evidence. This
   stage does not authorize changing the application Secret or enabling the
   receiver/probe.
3. **Isolated restore:** completed per-volume Backup evidence, baseline and
   restore-manifest SHA-256 values, 20 GiB nominal clone size, at least 24 GiB
   schedulable Longhorn headroom, exact namespace/PV/Volume names, read-only
   checks, stop conditions, and the separate restore cleanup plan. This stage
   does not select a production PVC, Volume, Backup, Secret, or Deployment for
   deletion or replacement.

Use the renderer rather than hand-writing `fromBackup` URLs. It rejects a
backup whose snapshot predates the captured baseline:

```bash
export RUN_ID=20261015a
BASELINE_FILE="./openstatus-baseline-${RUN_ID}.json" \
MAX_BACKUP_AGE_HOURS=2 \
  bash utils/render-openstatus-restore-drill.sh >"./openstatus-restore-${RUN_ID}.yaml"
kubectl apply --dry-run=client -f "./openstatus-restore-${RUN_ID}.yaml"
sha256sum "./openstatus-restore-${RUN_ID}.yaml"
RUN_ID="$RUN_ID" RESTORE_MANIFEST="./openstatus-restore-${RUN_ID}.yaml" \
  bash utils/cleanup-openstatus-restore-drill.sh --plan
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
- the baseline JSON SHA-256 and state (`initialized-empty` or `ingested`), the
  rendered manifest SHA-256, and its baseline/storage annotations;
- confirmation that no unrelated Longhorn or storage change is active;
- the exact `RUN_ID`, expected namespace/PV/Volume names, start window, and
  manifest-derived `cleanup-openstatus-restore-drill.sh --plan` output; and
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
  BASELINE_FILE="./openstatus-baseline-${RUN_ID}.json" \
  RUN_ID="$RUN_ID" PHASE=data bash utils/check-openstatus-restore-drill.sh
```

The data phase performs zero-write libSQL and Tinybird queries and compares the
exact counts and Tinybird state with the recorded pre-backup baseline. An
`initialized-empty` baseline must restore as initialized and empty; it does not
prove ingest recovery. An `ingested` baseline must restore with the exact
recorded rows, intervals, monitors, and regions. An `uninitialized` datasource
always fails. The workflows tree must also be readable from the pinned image.
`TINYBIRD_RESTORE_TOKEN` is supplied at execution time and is never committed
or printed.

Record two milestones separately: an initialized-empty restore before first
ingest, and a later ingested-data restore from a new post-ingest baseline and
new backups. Only the latter is evidence that stored monitoring results are
recoverable; it cannot be made a prerequisite for enabling the first ingest.

Stop immediately on a stale/missing backup, capacity shortfall, concurrent
storage work, restore error, non-healthy volume, unexpected resource without
the exact run label, failed inventory, data-query error, uninitialized or
baseline-mismatched data, unexpected egress, or any observed production
mutation. A successful mount without the libSQL and Tinybird reads is not a
successful drill.

Save the check output, then review the exact cleanup plan. Execution requires a
second run-id confirmation and considers only the three expected PV names,
three expected Longhorn Volume names, and the one run namespace; after a
partial apply it deletes only those that exist:

```bash
RUN_ID="$RUN_ID" RESTORE_MANIFEST="./openstatus-restore-${RUN_ID}.yaml" \
  bash utils/cleanup-openstatus-restore-drill.sh --plan
EXPECTED_MANIFEST_SHA256='<approved-manifest-sha256>' \
  CONFIRM_RUN_ID="$RUN_ID" RUN_ID="$RUN_ID" \
  RESTORE_MANIFEST="./openstatus-restore-${RUN_ID}.yaml" \
  bash utils/cleanup-openstatus-restore-drill.sh --execute
```

The static PVs use `Retain`; cleanup deletes the run namespace first, then only
the expected PV and restored Longhorn Volume names that actually exist. The
plan works before creation and after a partially failed apply. Both modes
validate the concrete manifest, exact run labels, PV→PVC→Longhorn Volume
bindings, Longhorn CSI driver and storage class, and the `Retain` policy; an
unexpected run-labeled name is a hard stop. Source backups and production
storage are never selected.

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

The default freshness limit is 300 seconds for both the newest stored result
and each private-location heartbeat; set `MAX_RESULT_AGE_SECONDS` or
`MAX_HEARTBEAT_AGE_SECONDS` only when the reviewed monitor cadence requires a
different bound. The check counts distinct successful `cronTimestamp` values,
requires the latest result to be successful and fresh, and rejects duplicate
success rows from one cycle, a later failed cycle, stale results, stale
heartbeats, and empty evidence.

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
