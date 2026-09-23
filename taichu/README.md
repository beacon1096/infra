# 太初（taichu）

太初是原 `swarm-01` 环境（更早称 Ember）的新名称。本目录保存 Harvester/RKE2 集群的公开配置与结构化清单；[设备库存](../docs/inventory/taichu/README.md)记录逐台硬件及最新核验结果，[双集群设计思路](../docs/inventory/cluster-design.md)说明它与万象的职责边界。访问方式与带外管理见私有仓对应目录。

## 历史采集边界

`inventory.yaml` 最初来自 2026-08-13 的只读调查。调查通过既有 SSH 入口查询 Harvester，没有把 kubeconfig 复制出节点；RouterOS 也仅作只读查询。原始导出、密钥、令牌和其他凭据不属于本仓。历史健康及租约记录不能代替当前集群状态，更不能作为删除配置的依据。

## 环境

三台 Harvester 节点 `mc5-01`、`mc4-01`、`mc4-02` 位于 RB5009 后的 `172.16.100.0/24` 管理网。路由器上联 `inbound` 使用 DHCP；太初可接入另一处局域网或光猫。平台版本、其他网段和当前设备硬件见清单，避免在多处复制。

旧 `swarm-01` 的 `172.16.107.0/24` / VLAN 1116 仍可在路由配置中看到。2026-08-13 调查时，`.201`、`.202`、`.203` 租约处于等待状态，约 14 周未活动且没有对应 ARP 项；这只说明当时旧端点未见在线，不是删除记录，也不证明今天仍未使用。

## 当时的工作负载与健康

2026-08-13 观察到运行中的用户虚拟机为 `identity/service-keycloak`，VMI 地址 `172.16.101.6`，位于 `mc5-01`；`development/service-gitlab` 和 `routine/service-nextcloud-aio` 当时停止。Longhorn 仍有这些应用及 Grafana、Alertmanager、Prometheus 的卷；Nextcloud 卷当时已分离且状态未知。

当时 `kube-system/ovn-central` 有 3 个 CrashLoopBackOff Pod，`0/3 Ready`；初次查看的 `kube-ovn-cni` 为 `2/3 Ready`。这些是历史观察，后续调查与最新运行状态见私有库存。此轮采集没有修改 Terraform、RouterOS、Harvester、Kubernetes 或 Flux，也没有执行备份恢复。

## 后续采用前的核对

1. 重新核验 OVN、Longhorn、备份目标与恢复能力。
2. 确认 RB5009 的信任边界，审查私有网络记录。
3. 明确 Terraform/GitOps 的资源所有权，只纳管安全且可验证的配置。
4. 在可能切断集群访问的变更前，确认带外入口与恢复顺序。
