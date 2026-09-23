# MS-01 `ms01-a`

Talos 控制面节点 `ms01-a`。

## 硬件信息

| 项目 | 2026-09-23 实机读取 |
| --- | --- |
| 机型 | Micro Computer (HK) Venus Series（MS-01） |
| BIOS | AMI `AHWSA.1.22`（2024-03-12） |
| CPU | Intel Core i9-12900H，14 核 20 线程 |
| 内存 | 64 GB：Micron/Crucial `CT64G56C46S5.M16B1` 一条，SMBIOS 速度 5600 MT/s；Talos 可见约 62.4 GiB |
| 系统盘 | KIOXIA `KXG80ZN84T09` NVMe，约 4.1 TB（厂商标称 4096 GB） |
| 网卡 | Intel X710 双口 10GbE SFP+、I226-V 与 I226-LM 2.5GbE、MediaTek MT7922 Wi-Fi 6 |
| 显示 | Intel Alder Lake-P 核显；未验证 Talos 中的 GPU 用途 |

两口 X710 配为 `bond0`，承载 VLAN 87。Talos 的内存模块资源未单独报告容量；64 GB 根据部件型号及系统内存总量判定，不据此推断 ECC 运行状态。

## 系统

2026-09-23 实机核验 Talos `v1.13.10` / Kubernetes `v1.36.4`。

## 网络位置

管理地址 `172.16.87.201`；带外地址 `172.16.81.1`。

## 运行状态

2026-09-23 核验为 Ready、可调度。

## 访问

Talos 不开放 SSH，通过 `talosctl` 管理。
