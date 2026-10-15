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

## MCP Follow-Up

OpenStatus exposes an API-key authenticated MCP endpoint. After the dashboard and status page are validated, create an API key from the OpenStatus UI if assistant access is needed. Prefer read-only keys for observation; use read/write keys only for deliberate incident/status-report automation.

Do not store long-lived MCP API keys in Git unless explicitly requested.

## Rollback

Revert the probe and receiver manifests through GitOps. Scaling down the probe stops new checks; scaling down the receiver also prevents probes from fetching monitor assignments and ingesting results. Do not delete private-location rows, monitors, or PVCs as part of rollback.
