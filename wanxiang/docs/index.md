# 万象：文档索引

本目录保存万象的 Talos/Kubernetes 文档；旧 `talos-i` 方案与太初现状应分开阅读：

| 集群 | 角色 | 当前说明 |
|---|---|---|
| **万象（旧 talos-ii）** | MS-01 裸机 Talos，主要业务 | 已运行；实测状态见[万象清单](../../docs/inventory/wanxiang/README.md) |
| **旧 talos-i 方案** | 太初 Harvester/KubeVirt 上的辅助 Talos | 历史设计，不等于当前运行集群；见[双集群设计](../../docs/inventory/cluster-design.md) |

## 设计与配置

- [双集群设计思路](../../docs/inventory/cluster-design.md) — 万象与太初的职责和技术取舍；当前状态见各集群清单
- [Talos image factory](talos-image-factory.md) — **schematic ID ↔ extension reverse map** (sectioned per cluster — must update in same commit as any image change)

## Decisions (ADR-style, append-only, organized per cluster)

ADRs are organized by their scope:

- [`decisions/shared/`](decisions/shared/) — applies to both clusters (e.g. SDD process)
- [`decisions/talos-ii/`](decisions/talos-ii/) — talos-ii-specific
- [`decisions/talos-i/`](decisions/talos-i/) — talos-i-specific (populated after adoption)

### Currently in this repo

#### Shared

- [shared/0001 — Spec-Driven Development with spec-kit](decisions/shared/0001-spec-driven-development.md)
- [shared/0002 — Mesh integration modes for K8s clusters](decisions/shared/0002-mesh-integration-modes.md) (accepted 2026-05-04 — Option C: Talos extension + subnet router)
- [shared/0003 — talos-i positioning: offsite observability + backup](decisions/shared/0003-talos-i-positioning.md) (accepted 2026-05-04 — residential, tailnet-only inbound, Tailscale-now/self-hosted-later; hypervisor TBD)

#### talos-ii

- [talos-ii/0001 — Bare-metal Talos on MS-01 (no Harvester / KubeVirt nesting)](decisions/talos-ii/0001-bare-metal-talos.md)
- [talos-ii/0002 — Longhorn as the single CSI](decisions/talos-ii/0002-longhorn-csi.md)
- [talos-ii/0003 — Direct VLAN 87 on UDM-Pro, no OVN](decisions/talos-ii/0003-vlan-87-direct-attach.md)
- [talos-ii/0004 — Official Talos image factory only, no custom extensions](decisions/talos-ii/0004-official-image-factory.md)
- [talos-ii/0005 — Enable UEFI Secure Boot with sd-boot](decisions/talos-ii/0005-secure-boot.md)
- [talos-ii/0006 — Disable PCIe ASPM in MS-01 BIOS (both PCH and SA groups)](decisions/talos-ii/0006-disable-pcie-aspm.md)
- [talos-ii/0007 — CloudNativePG as the postgres operator](decisions/talos-ii/0007-cloudnative-pg-operator.md)
- [talos-ii/0008 — Authentik on CloudNativePG, dump-restored](decisions/talos-ii/0008-authentik-cnpg-restore.md)
- [talos-ii/0009 — Matrix-synapse on CloudNativePG, pinned to PG 15](decisions/talos-ii/0009-matrix-synapse-cnpg-pg15.md)
- [talos-ii/0010 — Coder & n8n on CloudNativePG](decisions/talos-ii/0010-coder-n8n-cnpg.md)
- [talos-ii/0011 — Attic on CloudNativePG (Phase 4a)](decisions/talos-ii/0011-attic-cnpg.md)
- [talos-ii/0012 — zot in-cluster on talos-ii (Phase 4b)](decisions/talos-ii/0012-zot-on-talos-ii.md)
- [talos-ii/0013 — Forgejo Actions runner on talos-ii (DinD, hostNetwork)](decisions/talos-ii/0013-forgejo-runner-talos-ii.md)
- talos-ii/0014 — Tailscale host extension (**superseded 2026-05-05**; archived in the private infrastructure repository)

#### talos-i

*(populated after talos-i is adopted — initial entries will likely cover: keep Harvester KubeVirt on NEC8, retain custom `util-linux-mountpoint` extension, retain self-hosted image factory.)*

## Operations

- [Repository CI/CD and fleet delivery](../../docs/agentic/workflow/infra-ops/README.md) — release
  approval, protected merging, Forgejo service accounts, and Nix rollout.
- [Wanxiang off-site backups](operations/offsite-backup.md) — TrueNAS,
  routed NFS, Longhorn SystemBackup, and restore verification.
- [Syncthing introducer](operations/syncthing-introducer.md)

- [zot — multi-registry pull-through cache](operations/zot-mirror.md) — what the LAN registry on `172.16.80.240:5000` does, how nodes are configured to use it, performance characteristics, how to add an upstream.
- [Tailscale operator — exposing services on the tailnet](operations/tailscale-operator.md) — annotation-driven exposure, ProxyClass usage, and local OCI chart operation.
- Tailscale subnet router (host extension) — **superseded** runbook archived in the private infrastructure repository; current Tailscale usage is in-cluster.
- [Authentik restore from swarm-01 dump](operations/authentik-restore.md) — runbook for the one-time `kubectl exec | psql` load against the CNPG cluster. Required before authentik is usable on talos-ii.
- [Vaultwarden restore from swarm-01 tarball](operations/vaultwarden-restore.md) — one-shot busybox-pod pattern for loading sqlite + icon cache into the pre-created PVC.
- [Matrix-synapse restore from swarm-01 dump + media](operations/matrix-restore.md) — combines the authentik PG-restore pattern with the vaultwarden helper-pod media-untar pattern. Notes that the signing key wasn't exported (fresh one generated).
- [Coder restore from swarm-01 dump](operations/coder-restore.md) — straight psql-load + ownership-reassign. Workspace tarball (`coder-workspace.tar.gz`, 476 MB) deliberately not restored — workspaces re-provision from templates.
- [n8n restore from swarm-01 dump + state tarball](operations/n8n-restore.md) — psql-load plus busybox-pod state-tarball untar with `chown` since n8n runs as uid 1000.
- [Attic restore (Phase 4a runbook)](operations/attic-restore.md) — token mint, fleet rollout, rotation, cache creation via REST.
- [zot in-cluster operations (Phase 4b runbook)](operations/zot-restore.md) — image bump, chart upgrade, adding upstream registries, DR scenarios, decommission gate. Sibling to `zot-mirror.md` (LAN host).
- [Forgejo Actions runner — talos-ii operations runbook](operations/forgejo-runner.md) — pre-flight, token mint, cutover, verification, rollback, image bump, and registry mirror migration.
- [OpenStatus — uptime/status monitoring operations](operations/openstatus.md) — Flux deployment, OAuth secret gate, libSQL/Tinybird persistence, private-location setup, and MCP follow-up.
- [Flux + Helm recovery — stuck HelmReleases](operations/flux-helm-recovery.md) — when helm-controller restarts and loses release storage: soft (`suspend → resume`), hard (delete helm secrets), nuclear (also delete sts) recovery patterns. Cases: attic / zot / n8n / vaultwarden.
- (to be added: node replacement, Longhorn disk replacement, Talos upgrade)

## Open questions / known unknowns

- **Intel iGPU usage on talos-ii** — MS-01 has Iris Xe (Gen 12 IP). Want to enable for `immich` face recognition, transcoding, etc. Requires:
  - Decide between `i915` (mature, established for Gen 12) and `xe` (newer, designed for Arc / Battlemage; still rough on Gen 12)
  - Identify the right Talos system extension(s) — possibly firmware blobs (`guc`/`huc` for hardware accel) and userspace (`intel-vaapi-drivers` in pod images)
  - Currently **not** in the schematic; flip on later via constitution-conformant ADR + schematic update + this doc.
- **Cross-arch CI (arm64 / loongarch64) via Forgejo Runner on talos-i** — for Nix package builds and Docker `buildx --platform` multi-arch builds. The mechanism is `binfmt_misc` kernel module + `tonistiigi/binfmt` (or hand-written) registration of QEMU user-mode interpreters per architecture. Caveats:
  - This belongs to **talos-i** (where `forgejo-runner` runs), not talos-ii. The talos-ii forgejo *server* doesn't build anything.
  - Add `siderolabs/binfmt-misc` to talos-i's schematic when this is enabled
  - loongarch64 needs QEMU 7.0+ and `tonistiigi/binfmt` may not include the loongarch64 interpreter by default — may need a custom binfmt registration
  - For Nix, also need `boot.binfmt.emulatedSystems` analogue + `nix.settings.extra-platforms` so the Nix daemon accepts cross-arch derivations
- **High-bandwidth public exposure** — for any service hitting Cloudflare's body-size or fair-use limits (large media uploads), use the NixOS VPS + Tailscale + Caddy path described in [Constitution §VI](../.specify/memory/constitution.md#vi-public-exposure-both). The list of services on this path will grow over time; track in per-spec docs.
- **CloudNativePG PITR target** — add an S3-compatible off-site target for WAL
  archiving and base backups; Longhorn backups alone are not database PITR.
- **Multi-cluster mesh** between talos-i and talos-ii — not needed yet, but PodCIDRs are non-overlapping by design (10.42 vs 10.44)

## Conventions

- ADRs are numbered sequentially **per directory** (so `talos-ii/0001`, `talos-i/0001`, `shared/0001` can coexist). Never renumber. Status: `accepted` / `superseded by NNNN` / `rejected`.
- When `docs/talos-image-factory.md` changes, the **same commit** must update the schematic ID in `talos/clusters/<cluster>/talenv.yaml`. If splitting commits is unavoidable, the chain must merge atomically.
- This index file is the authoritative TOC. New docs land here in the same commit they're added.
- A new cluster joining the repo gets its own subdirectories under `decisions/`, `talos/clusters/`, and `kubernetes/clusters/`. The constitution stays single-file but is tagged per principle.
