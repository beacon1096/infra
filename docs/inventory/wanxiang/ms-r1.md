# ms-r1

NixOS 驻守节点。

## 硬件信息

| 项目 | 2026-09-23 实机读取 |
| --- | --- |
| 机型 | Micro Computer (HK) `MS-R1` |
| BIOS | `1.0`（2025-10-02） |
| CPU | ARM64 12 核：8× Cortex-A720 + 4× Cortex-A520 |
| 内存 | 64 GiB：SMBIOS 报告 4 × 16 GiB LPDDR5，配置速率 5500 MT/s；Linux 可见约 62 GiB |
| 系统盘 | KINGSTON `OM8PGP41024Q-A0` NVMe，约 953.9 GiB |
| 网卡 | 2 × Realtek RTL8127 10GbE；MediaTek MT7922 Wi-Fi 6 |

SMBIOS 报告内存阵列纠错类型为 `Single-bit ECC`，但未验证运行时 ECC 是否工作。

## 系统

NixOS，内核 `7.1.2`。

## 网络位置

LAN 地址 `172.16.80.240`；Tailscale `100.95.176.53`。

## 运行角色

是 本网络的 NixOS 驻守节点： 与路由器 UDM-Pro 联动。
网络交互能力：
- OSPF 代理
- MeshVPN
  - Tailscale: ExitNode | inbound | SubnetRouter

## 访问

SSH 用户 `beacon`。
