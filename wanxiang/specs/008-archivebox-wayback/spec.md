# Feature Specification: Self-hosted web archiving (ArchiveBox) on wanxiang

**Feature Branch**: `008-archivebox-wayback`
**Created**: 2026-09-30
**Status**: Draft
**Input**: User request: "出于文档记录的需要，我们需要一个自部署的 wayback machine，用于记录文档里面的一些历史参考信息（例如：ChatGPT 的 share 历史记录）。"

## Scope

Deploy one self-hosted ArchiveBox collection on the wanxiang (formerly talos-ii) cluster
so that references cited in our own documentation — for example ChatGPT share links —
can be snapshotted and replayed after the original URL rots or changes.

The MVP is intentionally narrow: a single Flux-managed ArchiveBox container reachable at
`wayback.${SECRET_DOMAIN}` (public via `envoy-external`, also on the Tailscale-internal
`envoy-internal`), a replicated Longhorn volume for the collection, SOPS-managed admin
credentials, and ArchiveBox's own admin login. Subdomain-per-snapshot replay isolation,
scheduled crawls, external storage backends, and SSO integration are deferred.

This is a new service. It does not replace, migrate, or import any existing archive.

## User Scenarios & Testing

### User Story 1 - Operator archives a reference URL (P1)

A tailnet operator opens the ArchiveBox admin UI, adds a URL (for example a ChatGPT
share link), and the snapshot is stored in the collection volume.

**Why this priority**: Capturing references is the entire point of the service; without
a working capture path there is nothing to preserve.

**Independent Test**: From a tailnet device, open `https://wayback.${SECRET_DOMAIN}/admin/`,
log in with the `admin` account, submit one URL, and confirm a snapshot entry is created
and its files exist after a pod restart.

**Acceptance Scenarios**:

1. **Given** Flux has reconciled the ArchiveBox manifests, **When** an allowed tailnet
   identity opens the admin hostname, **Then** the request routes through
   the Gateway to the ArchiveBox service on port 5797 and returns the admin UI.
2. **Given** `ADMIN_USERNAME`/`ADMIN_PASSWORD` are provided, **When** the collection is
   first initialized, **Then** an admin superuser is created and login succeeds without
   manual `kubectl exec`.
3. **Given** a URL is submitted, **When** the archive job completes, **Then** a snapshot
   directory and index entry exist under `/data`.

### User Story 2 - Archived references survive restarts (P1)

The collection is durable across pod reschedules and node-level failure.

**Why this priority**: An archive that disappears on restart provides no historical value.

**Independent Test**: Snapshot at least one URL, delete the pod, and verify the index and
snapshot files are still present after the replacement pod is ready.

**Acceptance Scenarios**:

1. **Given** at least one snapshot exists, **When** the pod is recreated, **Then**
   `index.sqlite3` and the snapshot folders remain.
2. **Given** the PVC is provisioned through `longhorn-r3`, **When** a single node is
   unavailable, **Then** the volume remains available from the other replicas.

### User Story 3 - Replay does not expose the admin control plane (P1)

Viewing an archived page does not let that page act as a logged-in admin.

**Why this priority**: Archived third-party HTML/JS is untrusted; serving it on the same
origin as the admin session without mitigation would be a stored-XSS-to-account-takeover
path.

**Independent Test**: Open a snapshot replay URL while logged out and confirm the page
renders without privileged controls, and that replay JS is neutered.

**Acceptance Scenarios**:

1. **Given** `SERVER_SECURITY_MODE=safe-onedomain-nojsreplay`, **When** a snapshot is
   replayed, **Then** risky replay JavaScript is neutered and the admin control plane
   stays behind its own login.
2. **Given** `PUBLIC_INDEX=true` and `SERVER_SECURITY_MODE=safe-onedomain-nojsreplay`,
   **When** an anonymous visitor opens a snapshot, **Then** the replay loads without
   privileged controls and the admin control plane remains behind login.

### Edge Cases

- **Chrome shared memory**: Extractors that use Chromium need an adequately sized
  `/dev/shm`; the default 64 MiB breaks archiving jobs.
- **Collection ownership**: The upstream entrypoint expects to adjust `/data` ownership
  to `PUID`/`PGID`; on Longhorn the mount is root-owned, so the container must start as
  root and drop to the archivebox user (the same pattern as `kasm-browser`).
- **Base URL and CSRF**: Without `BASE_URL`, generated links fall back to
  `archivebox.localhost` and form submissions fail behind the gateway.
- **Single writer**: ArchiveBox is a single-writer collection; two concurrently mounted
  pods against the same volume must never overlap.
- **First-run cost**: Initialization and first snapshot downloads are I/O and CPU heavy;
  readiness must tolerate a slow start.

## Requirements

### Functional Requirements

- **FR-001**: ArchiveBox MUST be deployed to wanxiang through Flux-managed manifests in
  this repository, using the shared `bjw-s` `app-template` chart like the other apps.
- **FR-002**: The collection MUST persist on a `longhorn-r3` `PersistentVolumeClaim`.
- **FR-003**: The service MUST be exposed through Gateway API HTTPRoute as
  `wayback.${SECRET_DOMAIN}` on `envoy-external` (public, via Cloudflare Tunnel) and
  `envoy-internal`.
- **FR-004**: The admin password MUST be SOPS-encrypted; no plaintext credential may be
  committed.
- **FR-005**: `BASE_URL` MUST be set to the external hostname so links and CSRF checks
  resolve correctly.
- **FR-006**: `SERVER_SECURITY_MODE` MUST be `safe-onedomain-nojsreplay` for the MVP
  single-hostname deployment.
- **FR-007**: The deployment MUST provide readiness/liveness probes against `/health/`.
- **FR-008**: Chromium MUST get a memory-backed `/dev/shm` and an Unconfined seccomp
  profile so archive jobs do not crash.
- **FR-009**: The controller MUST use `strategy: Recreate`.
- **FR-010**: The image MUST be consumed through the cluster registry mirror and pinned
  to a released ArchiveBox tag.
- **FR-011**: No Talos machine-config change, node reboot, or destructive storage
  operation may be required.

### Key Entities

- **ArchiveBox collection**: `/data` holding `index.sqlite3`, per-snapshot folders,
  logs, and browser personas.
- **Admin account**: superuser created once from `ADMIN_USERNAME`/`ADMIN_PASSWORD`.
- **HTTPRoute**: `wayback.${SECRET_DOMAIN}` on the `envoy-external` and `envoy-internal` gateways.
- **SOPS Secret**: `archivebox-secret` in the `archive` namespace.

## Success Criteria

- **SC-001**: All ArchiveBox pods are Ready after Flux reconciliation with no
  CrashLoopBackOff.
- **SC-002**: `https://wayback.${SECRET_DOMAIN}/admin/` returns the admin UI to an
  allowed tailnet client.
- **SC-003**: An operator can log in and archive one URL end to end.
- **SC-004**: Restarting the pod does not lose the index or snapshot files.
- **SC-005**: No plaintext credential appears in the committed diff.

## Assumptions

- The existing Flux, Gateway API, SOPS, Longhorn and Zot patterns remain available.
- `wayback.${SECRET_DOMAIN}` does not collide with an existing route.
- Upstream ArchiveBox deployment guidance (Docker Compose) is the source of truth for the
  container contract; no maintained Helm chart is adopted.
