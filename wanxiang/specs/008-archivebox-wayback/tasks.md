---
description: "Task list for self-hosted web archiving (ArchiveBox) on wanxiang"
---

# Tasks: Self-hosted web archiving (ArchiveBox) on wanxiang

**Input**: Design documents from `wanxiang/specs/008-archivebox-wayback/`
**Prerequisites**: spec.md, plan.md
**Target cluster**: wanxiang only.

**Tests**: Validation is operator-run: Flux readiness, HTTPRoute reachability, admin
login, one end-to-end snapshot, and a restart persistence check.

## Phase 1 — Author GitOps manifests

- [x] T001 Add `./archive` to `wanxiang/kubernetes/apps/kustomization.yaml`.
- [x] T002 Create namespace `archive` with prune disabled.
- [x] T003 Create `archive/archivebox/ks.yaml` with `postBuild.substituteFrom: cluster-secrets`.
- [x] T004 Create the app directory with `kustomization.yaml`, `ocirepository.yaml`,
  `pvc.yaml`, `secret.sops.yaml`, `helmrelease.yaml`.
- [x] T005 Pin the image tag and add the Renovate datasource annotation.

## Phase 2 — Validate

- [x] T006 Render the `archive` Kustomization and confirm the HelmRelease values.
- [x] T007 Confirm no plaintext secret is introduced (`check-secrets`).
- [x] T008 Confirm doc families changed together (`check-docs-i18n`).

## Phase 3 — Operator verification (post-merge / post-reconcile)

- [ ] T009 Confirm the `archivebox` Kustomization and pod become Ready.
- [ ] T010 Open `https://wayback.${SECRET_DOMAIN}/admin/` from an allowed tailnet device.
- [ ] T011 Archive one reference URL and confirm the snapshot appears.
- [ ] T012 Delete the pod and confirm the index and snapshots survive.
- [ ] T013 Record the observed hostname, storage usage and any deviations in the issue.
