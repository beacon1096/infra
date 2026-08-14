# Ember

Ember is the name assigned to the original `swarm-01` environment. This directory is a first, read-only inventory of the Harvester cluster, its dedicated RB5009 network, and the workloads observed during onboarding.

## Scope and observation

- Observation date: 2026-08-13.
- The cluster was queried through the existing SSH access. The Harvester kubeconfig was not copied out of the node; queries used `sudo` on `mc5-01` with `/etc/rancher/rke2/rke2.yaml`.
- RouterOS was queried read-only. No raw RouterOS export, kubeconfig, key, token, or other credential belongs in this repository.
- This is documentation and inventory only. No Terraform, RouterOS, Harvester, Kubernetes, or Flux change was made, and no backup or restore was run.
- The structured facts are in [`inventory.yaml`](./inventory.yaml). Transient health and lease observations are intentionally marked as observations and need revalidation before an automation change.

## Environment

The three-node Harvester installation is on the dedicated network behind `172.16.100.254` (the RB5009). The router's upstream is DHCP on `inbound`, so the dedicated network can be uplinked to another home network or directly to an optical modem as described by the owner.

The Harvester nodes are `mc5-01` (`172.16.100.201`), `mc4-01` (`172.16.100.202`), and `mc4-02` (`172.16.100.203`). All three were `Ready` control-plane/etcd/master nodes at observation time. The platform versions and network ranges are recorded in `inventory.yaml` rather than duplicated in multiple documents.

The old `swarm-01` VLAN remains represented in the router configuration as `172.16.107.0/24` / VLAN 1116. Its `.201`, `.202`, and `.203` DHCP leases were waiting and had last been seen roughly 14 weeks earlier; there were no corresponding ARP entries during collection. This supports the conclusion that the old swarm endpoints were inactive at that time, but it is not a deletion record.

## Workloads and health

At observation time, `identity/service-keycloak` was the only running user VM, with VMI address `172.16.101.6` on `mc5-01`. `development/service-gitlab` and `routine/service-nextcloud-aio` were stopped. Longhorn still contained volumes for all three application areas plus Grafana, Alertmanager, and Prometheus; the Nextcloud volume was detached and unknown.

`kube-system/ovn-central` had three `CrashLoopBackOff` pods and was `0/3 Ready`, with probes reporting that `ovn-northd` was not running. The initial DaemonSet view also showed `kube-ovn-cni` at `2/3 Ready`. Longhorn's default backup target was unavailable and no Backup objects were found. These are follow-up items, not changes made by this inventory.

## Follow-up before adoption

1. Recheck the OVN and Longhorn health observations and establish a tested backup target before any workload or storage change.
2. Confirm the intended RB5009 trust boundary and review the firewall/service exposure, UPnP/NAT-PMP, and anonymous proxy settings recorded in the inventory.
3. Decide the desired Terraform/GitOps ownership boundary, then add only the declarative configuration that is safe to manage from this repository.
4. Capture an approved recovery and out-of-band access path before changes that could cut off the agent or the cluster.
