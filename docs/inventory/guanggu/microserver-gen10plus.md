# HPE ProLiant MicroServer Gen10 Plus

## 硬件信息

| 硬件项目 | 信息 |
| --- | --- |
| 机型 | HPE ProLiant MicroServer Gen10 Plus |
| BIOS | HPE U48 v2.80（2023-07-20） |
| CPU | Intel CC150，8 核 16 线程，当前 3.50 GHz |
| 内存 | 64 GiB，2 × 32 GiB DDR4 UDIMM，双 rank；标称 3200 MT/s，当前配置 2667 MT/s |
| 内存总线 | DMI 报告数据宽度 64 bit、总宽度 72 bit及 Multi-bit ECC 能力 |
| 磁盘 | 3 × KIOXIA-EXCERIA SATA SSD，型号容量约 960 GB/块（实测约 894.3 GiB/块） |

## 系统

- 主机名：`microserver-gen10plus`
- NixOS 26.05 (Yarara)
- 内核：`7.1.3-cachyos-lto`

## 网络位置

光谷 `172.16.20.11`；Tailscale `100.121.229.9`。

## 运行角色

是 本网络的 NixOS 驻守节点： 与路由器 UCG-Fiber 联动。
网络交互能力：
- OSPF 代理
- MeshVPN
  - Tailscale: ExitNode | inbound | SubnetRouter
一般能力：
- Forgejo Runner: nix-builder
- Renovate

## 访问凭据

SSH 登录说明及 iLO 凭据见私有仓 `infra-private/docs/inventory/guanggu/microserver-gen10plus.md`。
