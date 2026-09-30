# ArchiveBox — self-hosted web archiving

**Namespace**: `archive` · **Flux Kustomization**: `flux-system/archivebox` ·
**Hostname**: `wayback.${SECRET_DOMAIN}` (Tailscale-internal, `envoy-internal`) ·
**Storage**: `archivebox-data` (`longhorn-r3`, 50Gi RWO) ·
**Image**: `mirror.gcr.io/archivebox/archivebox:0.9.71`

## What it is

A single ArchiveBox collection used to preserve references cited in our own
documentation — for example ChatGPT share links — so they can be replayed after the
source URL rots or changes. It is not a general public web archive and is not exposed
on the public ingress.

## How it runs

One `app-template` controller runs the upstream image with its default command
(`archivebox server --init 0.0.0.0:5797`). The entrypoint starts as root, repairs
ownership of `/data` to `PUID`/`PGID` (`911`), and drops privileges to the `archivebox`
user. Chrome needs an Unconfined seccomp profile and a 1Gi memory-backed `/dev/shm`;
without either, archiving jobs crash.

`SERVER_SECURITY_MODE=safe-onedomain-nojsreplay` serves archived pages from the same
host as the admin UI with risky replay JavaScript neutered. This is the safe mode for a
single non-wildcard hostname: administrators stay behind the admin login, and archived
(untrusted) pages cannot run privileged scripts. Full JavaScript replay would require
`safe-subdomains-fullreplay` plus wildcard DNS/TLS for per-snapshot subdomains — not
enabled in the MVP.

## Access

- Admin: `https://wayback.${SECRET_DOMAIN}/admin/`, user `admin`.
- The password lives in `archivebox-secret` (`admin-password`) in
  `wanxiang/kubernetes/apps/archive/archivebox/app/secret.sops.yaml`. Retrieve it with:

  ```bash
  sops -d wanxiang/kubernetes/apps/archive/archivebox/app/secret.sops.yaml \
    | yq '.stringData.admin-password'
  ```

- The admin account is created once, on first initialization, from
  `ADMIN_USERNAME`/`ADMIN_PASSWORD`. Changing the secret after initialization does not
  rotate the existing account; use `archivebox manage changepassword` inside the pod or
  the admin UI.

## Common operations

```bash
# add a URL from inside the cluster
kubectl -n archive exec deploy/archivebox -- archivebox add --depth=1 'https://example.com'

# list newest snapshots
kubectl -n archive exec deploy/archivebox -- archivebox list --sort=added --limit=10

# tail server logs
kubectl -n archive logs deploy/archivebox -f
```

Scheduled crawls (`archivebox schedule --add ...`) are processed by the in-process
orchestrator; they are not configured in the MVP.

## Data and recovery

All durable state is under `/data` on the `archivebox-data` PVC: `index.sqlite3`,
per-snapshot folders, logs, and browser personas. `SECRET_KEY` is generated once and
persisted into the collection config, so sessions survive restarts.

Confirm that `archivebox-data` is inside the Longhorn backup target before relying on
off-site recovery; this change does not add a dedicated backup job. To restore, restore
the volume from a Longhorn backup snapshot and reschedule the pod.

**Retracting the app**: reverting the manifests prunes the Flux-managed PVC and destroys
the archive. To keep data while removing the workload, mark the PVC
`kustomize.toolkit.fluxcd.io/prune: disabled` (or snapshot it) before reverting.

## Updating

The image tag carries a Renovate annotation; bump the tag in `helmrelease.yaml` (and, if
desired, pin the digest) and let Flux reconcile. The `app-template` chart version is
shared with the other apps.
