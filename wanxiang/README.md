# 万象（wanxiang）

万象是原 `talos-ii` 集群的新名称。本目录保存 Talos、Kubernetes 和 Flux 的公开声明配置；[设备库存](../docs/inventory/wanxiang/README.md)记录逐台硬件与最新核验，[双集群设计思路](../docs/inventory/cluster-design.md)说明它与太初的分工。结构化历史与当前观察见 [`inventory.yaml`](inventory.yaml)。

## 网络与集群

万象由三台 MS-01 裸机 Talos 控制平面节点组成，地址为 `172.16.87.201`、`.202`、`.203`。每台通过双口 X710 LACP bond 接入 VLAN 87；UDM-Pro 在 `172.16.87.254` 提供网关，Kubernetes API VIP 为 `172.16.87.1`。显示名称的更改不自动改变技术上的 `clusterName: kubernetes` 或既有证书 SAN `talos-ii.beaco.works`。

2026-09-23 只读核验：UDM-Pro 上联为 `172.16.20.253/24`；到 `1.1.1.1` 的路由经 OSPF 邻居 `ms-r1`（`172.16.80.240`）。三台节点均为 Ready、可调度，Talos 为 `v1.13.10`，Kubernetes 为 `v1.36.4`。旧记录中的 `.20.216`、Talos `v1.12.7`、Kubernetes `v1.35.4` 和 `ms01-c` cordon 状态均非本次实测现状。硬件差异见逐台设备文档。

集群声明配置在 `talos/` 与 `kubernetes/`；公私两套 Flux 来源、运行工作负载和备份状态须分别核对，不能仅凭仓库存在清单就认定已部署或恢复可用。私有应用与操作入口见 `infra-private/wanxiang/`，明文凭据、kubeconfig、Talos 客户端配置、序列号和原始设备导出不进入本仓。

## 来源迁移

本目录由旧 `swarm` 树迁入。源切换的门禁与回滚步骤见 [`MIGRATION.md`](MIGRATION.md)；文件已迁入 `infra` 不代表运行中的 Flux 一定已切换来源。实际 GitRepository 与 Kustomization 状态需从集群核验，迁移不能仅靠改动这里的 README 完成。
