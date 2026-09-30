# Implementation Plan: Self-hosted web archiving (ArchiveBox) on wanxiang

**Branch**: `008-archivebox-wayback` | **Date**: 2026-09-30 | **Spec**: [spec.md](./spec.md)

## Summary

Add a new `archive` namespace and an `archivebox` Flux Kustomization to
`wanxiang/kubernetes/apps`. The workload is a single ArchiveBox container rendered by
the shared `bjw-s` `app-template` chart (the same chart family as `kasm-browser`,
`searxng`, `syncthing`, `n8n` and `forgejo`). It mounts a `longhorn-r3` PVC at `/data`,
a memory-backed `/dev/shm` for Chrome, and an `emptyDir` at `/tmp/archivebox`, and is
routed on `envoy-internal` as `wayback.${SECRET_DOMAIN}`.

The upstream container contract was verified against ArchiveBox `v0.9.71`
(Dockerfile `CMD ["archivebox", "server", "--init", "0.0.0.0:5797"]`, `EXPOSE 5797`,
health route `/health/`). Environment names (`BASE_URL`, `SERVER_SECURITY_MODE`,
`ADMIN_USERNAME`, `ADMIN_PASSWORD`, `PUID`, `PGID`, `PUBLIC_INDEX`, `PUBLIC_ADD_VIEW`)
are read directly, unprefixed.

## Technical Context

- **Workload type**: single stateful web application (Django) plus in-process
  archiving workers (Chromium).
- **Target cluster**: wanxiang (former talos-ii) only.
- **Namespace**: new `archive`.
- **Chart**: `oci://zot.registry.svc.cluster.local:5000/charts/app-template` tag `4.6.2`.
- **Image**: `mirror.gcr.io/archivebox/archivebox:0.9.71` (Zot pull-through of Docker Hub).
- **Storage**: `archivebox-data`, `longhorn-r3`, 50Gi `ReadWriteOnce`.
- **Ingress**: HTTPRoute on `envoy-internal`, hostname `wayback.${SECRET_DOMAIN}`.
- **Secrets**: `archivebox-secret` SOPS-encrypted with the wanxiang `.sops.yaml`
  (`encrypted_regex: ^(data|stringData)$`).
- **Reconciler**: Flux `Kustomization` with `postBuild.substituteFrom: cluster-secrets`
  for `${SECRET_DOMAIN}`.
- **Constraints**: no public route, no machine-config change, no destructive storage
  operations, no plaintext secrets, no NodePort.

## Conformance

- **Storage**: Longhorn `longhorn-r3`; no PVC deletion or resize in this change.
- **Network**: Cilium + Gateway API; Tailscale-internal exposure only.
- **Image factory**: untouched.
- **Secrets**: all credentials SOPS-encrypted; the secret scanner must pass.
- **GitOps**: all resources are declarative under `kubernetes/apps/*`; no manual apply.
- **Spec-driven**: this spec, plan and tasks accompany the manifests.
- **No surprise reboots**: pure workload change.

## Decisions and rationale

- **ArchiveBox over hosted archiving**: self-contained; no dependency on the Internet
  Archive or third-party archiving services, so snapshots remain under our control.
- **Single container**: ArchiveBox `0.9.x` runs its own scheduler inside `server`, so no
  separate worker/scheduler sidecar is required for the MVP.
- **`safe-onedomain-nojsreplay`**: the safe single-hostname mode. It keeps the admin
  control plane enabled, neuters risky replay JS, and avoids requiring wildcard DNS/TLS
  for subdomain-per-snapshot isolation. Full-JS replay would require
  `safe-subdomains-fullreplay` plus wildcard routing, deferred to a later change.
- **`envoy-internal`**: archived third-party content and personal references are not
  published in the MVP; the replay surface can be reviewed before any public route.
- **Root then drop**: matching upstream and `kasm-browser`; root is used only to repair
  `/data` ownership, then the process drops to uid/gid 911.
- **Unconfined seccomp + `/dev/shm`**: required for the Chromium-based extractors.
- **Explicit `BASE_URL`**: otherwise generated URLs fall back to `archivebox.localhost`
  and Django CSRF rejects form posts through the gateway. `CSRF_TRUSTED_ORIGINS` is
  derived automatically from `BASE_URL`, so it is not set separately.
- **`SECRET_KEY` not baked into SOPS**: ArchiveBox persists a generated `SECRET_KEY`
  into the collection config on first use, so the PVC already makes sessions stable.

## Project Structure

```text
wanxiang/
├── kubernetes/apps/
│   ├── kustomization.yaml                      # add ./archive
│   └── archive/
│       ├── namespace.yaml
│       ├── kustomization.yaml
│       └── archivebox/
│           ├── ks.yaml
│           └── app/
│               ├── kustomization.yaml
│               ├── ocirepository.yaml
│               ├── pvc.yaml
│               ├── secret.sops.yaml
│               └── helmrelease.yaml
├── specs/008-archivebox-wayback/{spec,plan,tasks}.md
└── docs/operations/archivebox.md
```

## Risks

- **First snapshot resource spike**: Chromium plus downloads can briefly exceed the
  request; the 3Gi memory limit and a generous readiness probe cover the MVP.
- **Longhorn single-writer**: `strategy: Recreate` and `ReadWriteOnce` prevent overlap.
- **Image drift**: version is pinned and annotated for Renovate.
- **Replay fidelity**: `nojsreplay` intentionally trades interactive fidelity for
  same-origin safety; JS-heavy pages may not fully replay. Automated, subdomain-isolated
  full replay is a follow-up.

## Rollback

Revert the commit that adds the `archive` app. Flux prunes the resources it created,
including `archivebox-data`; because the PVC is Flux-managed, a plain revert destroys the
archive. To retract while keeping data, first take the PVC out of the Flux-managed set
(annotate `kustomize.toolkit.fluxcd.io/prune: disabled` or snapshot the volume) before
reverting. No cluster-wide or node-level change is involved.
