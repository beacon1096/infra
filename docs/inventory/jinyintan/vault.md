# X10SDV-4C-TLN2F / vault

HPE ProLiant MicroServer Gen8 机箱中的 Supermicro X10SDV-4C-TLN2F。

## 硬件信息（2026-09-23）

| 项目 | 已核验信息 |
| --- | --- |
| 机箱 | HPE ProLiant MicroServer Gen8 |
| 主板 | Supermicro X10SDV-4C-TLN2F，版本 2.02 |
| BIOS | 2.3（2022-10-10） |
| CPU | Intel Xeon D-1521，4 核 8 线程 |
| 内存 | 40 GB：8 GB Hynix DDR4（标称 2667 MT/s）+ 32 GB DDR4（标称 3200 MT/s）；SMBIOS 报告当前配置速率均为 2133 MT/s |
| 内存纠错 | SMBIOS 报告纠错类型 None，已安装模块数据宽度均为 64 bit；未据此推断运行时 ECC 能力 |
| 硬盘 | `ST16000NM000J-2TW103` SATA，16 TB |
| NVMe | Samsung `MZAL41T0HBLB-00BL2`，1 TB |
| 有线网络 | Intel X552/X557-AT 双口 10GBASE-T |

## 系统

TrueNAS；同时承载 NixOS 容器。

## 网络位置

主机名 `vault`；金银潭地址 `172.16.10.21`。

## 运行角色

TrueNAS 备份节点，并承载 NixOS 容器。
NixOS容器 为本网络的 NixOS 驻守节点： 与路由器 hap-ax2 联动。
网络交互能力：
- MeshVPN
  - Tailscale: ExitNode | inbound | SubnetRouter

## 私有运维信息

SSH 访问、带外管理、存储配置及 `br19` 历史用途见私有仓 `infra-private/docs/inventory/jinyintan/vault.md`。
