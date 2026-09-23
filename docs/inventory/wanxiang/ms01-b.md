# MS-01 `ms01-b`

Talos 控制面节点 `ms01-b`。

## 硬件信息

| 项目 | 2026-09-23 实机读取 |
| --- | --- |
| 机型 | Micro Computer (HK) Venus Series（MS-01） |
| BIOS | AMI `AHWSA.1.22`（2024-03-12） |
| CPU | Intel Core i9-12900H，14 核 20 线程 |
| 内存 | 32 GB：Micron/Crucial `CT24G56C46S5.M8C1` 24 GB + Samsung `M425R1GB4BB0-CWMOD` 8 GB；SMBIOS 速度均为 5600 MT/s，Talos 可见约 31.0 GiB |
| 系统盘 | KIOXIA `KXG80ZN84T09` NVMe，约 4.1 TB |
| 网卡 | Intel X710 双口 10GbE SFP+、I226-V 与 I226-LM 2.5GbE、MediaTek MT7922 Wi-Fi 6 |
| 显示 | Intel Iris Xe 核显；未验证 Talos 中的 GPU 用途 |

两口 X710 配为 `bond0`，承载 VLAN 87。内存容量由部件型号及系统内存总量交叉核对；未验证 ECC 运行状态。

## 系统

2026-09-23 实机核验 Talos `v1.13.10` / Kubernetes `v1.36.4`。

## 网络位置

管理地址 `172.16.87.202`；带外地址 `172.16.81.2`。

## 运行状态

2026-09-23 核验为 Ready、可调度。

## 访问

Talos 不开放 SSH，通过 `talosctl` 管理。
