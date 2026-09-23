# 太初与万象：双集群设计思路

万象（旧称 `talos-ii`）承载主要业务；太初的 Harvester 集群提供虚拟化与独立恢复能力。旧方案还规划了运行在太初虚拟机中的 `talos-i`，用于观测和异地备份，但不能把该规划等同于目前已运行的集群。设备与实时配置分别见[万象清单](wanxiang/README.md)、[太初清单](taichu/README.md)及各自的声明配置。

## 为什么区分两种集群

| 维度 | 万象：主业务集群 | 太初：虚拟化与辅助集群 |
| --- | --- | --- |
| 硬件 | 3 台 MS-01，Talos 裸机运行 | 3 台 NEC 小主机运行 Harvester；旧 `talos-i` 方案使用 KubeVirt 虚拟机 |
| 主要职责 | 身份、协作、开发、镜像仓库等面向用户的服务 | 虚拟机、构建器；原设计将跨集群观测与备份接收端放在独立位置 |
| 恢复路径 | Secure Boot、TPM 磁盘加密与 Talos API；仍需验证备份恢复 | Harvester Web UI 与 KubeVirt 可作为虚拟机救援入口，减少裸机现场维护依赖 |
| 存储边界 | Talos 节点上的 Longhorn | Harvester 自身的 Longhorn；如运行 Talos 虚拟机，还涉及 Harvester CSI 与磁盘热插拔限制 |

两侧不共用故障域。观测系统放在被观测集群之外，可在万象故障时继续发现问题；异地备份还要求物理站点、网络和恢复流程独立。跨集群访问依赖路由或安全覆盖网络，不假定两套集群共享二层网络。是否启用旧 `talos-i`、部署在哪个站点，以及具体备份接收方式，均需以当前配置和恢复测试重新确认。

## 万象的技术取舍

万象选择 MS-01 裸机 Talos，避免 Harvester/KubeVirt 嵌套造成的额外网络、存储和排障层。三台控制平面节点通过双口 Intel X710 的 LACP bond 接入 VLAN 87，API VIP 为 `172.16.87.1`；当前 bond 与 VLAN 声明 MTU 为 1500。Cilium 负责容器网络，Longhorn 提供持久卷，CloudNativePG 管理需要 PostgreSQL 的服务。外部入口、镜像分发和服务级访问由各自声明配置管理。

Talos 使用官方镜像工厂、UEFI Secure Boot 和 TPM 封存的磁盘加密密钥。iGPU 未作为已投入使用的能力记录。版本、实际硬件配置、运行状态及工作负载可能改变，不在这份设计文档中固定；见[万象结构化清单](../../wanxiang/inventory.yaml)和 `wanxiang/talos/`、`wanxiang/kubernetes/`。

原方案将集群服务地址放在 VLAN 87 网段前部、物理节点放在 `.201`—`.203`：API VIP `.1`，外部/内部 Envoy 分别预留 `.11`/`.21`，`k8s-gateway` 预留 `.31`，镜像仓库曾预留 `.41`。这些是地址规划，不保证每个服务现在都使用该地址；实际分配以当前 Cilium、Gateway 和服务清单为准。

持久数据的设计是 Longhorn 作为单一 CSI：普通卷使用默认 StorageClass，重要数据可按工作负载选择三副本类；需要 PostgreSQL 的服务由 CloudNativePG 管理，不能以卷副本替代数据库备份。旧工作负载规划涵盖身份、协作、开发、镜像仓库与监控等应用，但应用是否仍部署、数据从哪里恢复，应逐项看现行 GitOps 配置和集群状态。对外入口原方案区分 Cloudflare Tunnel、私有入口及高带宽专用路径；不要由此推断所有服务的当前暴露方式。

备份目标已有声明配置与[异地备份运行手册](../../wanxiang/docs/operations/offsite-backup.md)，但“配置了目标”“备份可用”和“恢复成功”是三个不同结论。任何生产依赖都需要实际验证卷备份、元数据备份和应用级恢复。

## 太初与旧 `talos-i` 方案

太初的 NEC 节点缺少与 MS-01 相同的带外救援条件，因此保留 Harvester 虚拟化层。旧 `talos-i` 设计曾计划把观测和共享服务放在 Harvester KubeVirt 中，以便通过宿主平台进行远程救援；若继续采用该方案，存储必须考虑 Harvester CSI 的挂载与热插拔行为，不能直接照搬万象的裸机 Longhorn 配置。

旧设计中的 `172.16.107.0/24` 和 API VIP `172.16.107.1` 是 `talos-i` 的历史网络规划，不表示今天有三台 Talos 虚拟机正在运行。太初现有 Harvester、虚拟机、存储和网络状态见[太初清单](taichu/README.md)；是否恢复 `talos-i` 以及是否把观测与备份放到真正异地，应先确认容量、可达性和恢复顺序。

旧方案为 `talos-i` 选择观测、告警、异地备份接收及少量共享服务，而不是再次承载万象的全部主业务。它曾考虑自建 Talos 镜像工厂，并因 Harvester CSI 的挂载路径要求加入 `util-linux-mountpoint` 扩展；这与万象尽量使用官方 Talos 镜像、避免宿主层定制的取舍不同。具体版本、扩展和镜像地址必须重新核验，不能直接重用旧规划。

若决定重新采用 `talos-i`，顺序应是先验证 Harvester 容量、远程救援与独立备份，再确认网络/覆盖网可达性及存储兼容性，然后建立 Talos 与 GitOps 的声明配置，最后迁入观测等服务并做故障、恢复演练。原文中“迁入某仓库”“退役旧仓库”等步骤属于当时的迁移计划，不是当前必须照做的操作。

## 不从设计推断的事项

- 仓库中存在清单、HelmRelease 或备份目标，不代表对应工作负载健康，也不代表恢复测试完成。
- 历史设计中的副本数、镜像方案、服务清单和迁移阶段不是当前运行状态；以集群 API 和声明配置分别核验。
- 生产故障恢复仍需要带外访问、备份可用性与实际恢复演练，不能仅依赖双集群拓扑。

取舍的背景见万象 ADR：`wanxiang/docs/decisions/talos-ii/0001-bare-metal-talos.md`、`wanxiang/docs/decisions/shared/0003-talos-i-positioning.md`。本文是跨集群设计说明，不替代设备清单或运行手册。
