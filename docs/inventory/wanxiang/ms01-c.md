# MS-01 `ms01-c`

Talos 控制面节点 `ms01-c`。

## 硬件信息

| 项目 | 2026-09-23 实机读取 |
| --- | --- |
| 机型 | Micro Computer (HK) Venus Series（MS-01） |
| BIOS | AMI `1.27`（2025-04-03），与 a/b 不同 |
| CPU | Intel Core i9-12900H，14 核 20 线程 |
| 内存 | 56 GB：Micron/Crucial `CT48G56C46S5.M16B1` 48 GB + Samsung `M425R1GB4BB0-CWMOD` 8 GB；SMBIOS 速度均为 5600 MT/s，Talos 可见约 54.6 GiB |
| 系统盘 | KIOXIA `KXG80ZN84T09` NVMe，约 4.1 TB |
| 网卡 | Intel X710 双口 10GbE SFP+、I226-V 与 I226-LM 2.5GbE、MediaTek MT7922 Wi-Fi 6 |
| 显示 | Intel Iris Xe 核显；未验证 Talos 中的 GPU 用途 |

两口 X710 配为 `bond0`，承载 VLAN 87。内存容量由部件型号及系统内存总量交叉核对；未验证 ECC 运行状态。

## 系统

2026-09-23 实机核验 Talos `v1.13.10` / Kubernetes `v1.36.4`。

## 网络位置

管理地址 `172.16.87.203`；带外地址 `172.16.81.3`。

## 运行状态

2026-09-23 核验为 Ready、可调度；2026-08-14 的 cordon 记录已过时。带外地址 `.81.3` 来自既有记录，主机名尚待实机确认。

## 访问

Talos 不开放 SSH，通过 `talosctl` 管理。
