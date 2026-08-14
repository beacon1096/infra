# Infrastructure inventory

This repository currently records exactly two independent clusters:

| Display name | Stable directory | Former technical/display name | Platform |
|---|---|---|---|
| 太初 | [`taichu/`](./taichu/) | Ember; legacy `swarm-01` | Harvester on NEC nodes behind RB5009 |
| 万象 | [`wanxiang/`](./wanxiang/) | `talos-ii` | Talos on MS-01 nodes behind the UDM-Pro/“UDR-Pro” gateway |

The directory names use ASCII pinyin for shell and automation compatibility; the Chinese display names are the current cluster names. No third cluster is recorded here.

## Credential and configuration locations

Paths below are locations, not credential contents. None of the credentials belongs in Git.

### 太初 (`taichu/`)

- Harvester/RKE2 kubeconfig: on `mc5-01` (`172.16.100.201`) at `/etc/rancher/rke2/rke2.yaml`; it is root-owned and was read through `sudo` only. It was not copied to the local workspace.
- Talos config: not applicable; 太初 is the Harvester/RKE2 environment, not the Talos cluster.
- RouterOS configuration: no raw export is stored; `taichu/inventory.yaml` contains only the read-only, non-secret summary.

### 万象 (`wanxiang/`)

- Declarative Talos source: `swarm/talos/talconfig.yaml` in the `swarm` repository.
- Talos client credential (`TALOSCONFIG`): runtime mount `/run/coder-infra/talosconfig`.
- Kubernetes client credential (`KUBECONFIG`): runtime mount `/run/coder-infra/kubeconfig`.
- SOPS AGE key file (`SOPS_AGE_KEY_FILE`): runtime mount `/run/coder-infra/sops-age-keys`.
- Local convenience links, all ignored by Git: `swarm/.private/{talosconfig,kubeconfig,sops-age-keys}` and `infra/.private/{talosconfig,kubeconfig,sops-age-keys}`. They point to the runtime mounts and do not contain copied credential material.
- The display rename does not change the live cluster's technical `clusterName: kubernetes`, API VIP, or existing `talos-ii.beaco.works` certificate SAN. Changing those values would be a separate, approved cluster configuration change.

See each cluster directory for the observed topology, workloads, health notes, and recovery gaps.
