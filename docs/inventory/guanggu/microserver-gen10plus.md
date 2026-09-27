# HPE ProLiant MicroServer Gen10 Plus

## 硬件信息

| 硬件项目 | 信息 |
| --- | --- |
| 机型 | HPE ProLiant MicroServer Gen10 Plus |
| BIOS | HPE U48 v2.80（2023-07-20） |
| CPU | Intel CC150，8 核 16 线程，当前 3.50 GHz；仅 AVX2（无 AVX-512） |
| 内存 | 64 GiB，2 × 32 GiB DDR4 UDIMM，双 rank；标称 3200 MT/s，当前配置 2667 MT/s |
| 内存总线 | DMI 报告数据宽度 64 bit、总宽度 72 bit 及 Multi-bit ECC 能力；当前内核未启用 ECC（`EDAC ie31200: No ECC support`） |
| 磁盘 | 3 × KIOXIA-EXCERIA SATA SSD，型号容量约 960 GB/块（实测约 894.3 GiB/块），组成 RAID5 + Btrfs，承载 `/`、`/nix`、`/home` |
| GPU | NVIDIA RTX A2000 12 GiB（PCI `10de:2571`，Ampere sm_86）；持续负载下供电不稳，见下文 |
| 电源 | 原装 HP DC 圆孔外置 200 W；已更换为 Alienware 300 W，仍不足以支撑 A2000 持续满载 |

## 系统

- 主机名：`microserver-gen10plus`
- NixOS 26.05 (Yarara)
- 内核：`7.1.3-cachyos-lto`
- 2026-09-24 只读检查：PCI 设备 `10de:2571` 可见，但显卡未绑定驱动；当前启动环境中 `modinfo nvidia` 报模块不存在，`nvidia-smi` 无法与驱动通信。原因是本机公开模块用 `mkForce` 覆盖外置内核模块列表，排除了私有仓 NVIDIA 配置追加的模块。公开模块已调整为启用 NVIDIA 时把它与 VMware 模块一并保留；尚未构建部署和复测。
- 2026-09-28 复核：gen 27–37 的 `kernel-modules` 均不含 `nvidia.ko`（只有 in-tree 的 `nvidiafb`、`nvidia-wmi-ec-backlight`）。此前一次开机中 `nvidia-smi` 可用，是因为更早启动时加载进内存的模块在后续 `nixos-rebuild switch` 后一直存活；重启即失效。**恢复 GPU 需要带私有仓 NVIDIA 模块重新构建部署，单靠重启无效。**

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

## GPU 持续负载与供电

2026-09-28 的一次持续推理实验暴露了新的供电故障：

- 现象：运行约 1 小时后，iLO 报 Critical——
  `Runtime Fault, System Board, P12V Main/AUX Regulators (10h)`，
  整机随即断电（`PowerState: Off`、`State: Disabled`）。iLO 自身以及风扇、内存、电源、CPU、存储、温度各项均为 OK，唯 `BiosOrHardwareHealth` 为 Critical。
  重启后 iLO 健康恢复 OK，IML 仍保留该条历史故障，之后未再复现。
- 阵列：`md127` RAID5 全程 `[3/3] [UUU]` 健康，未参与故障；`dmesg` 无 MCE / EDAC 错误。故障不在磁盘。
- 用户经验：A2000 长时间打游戏同样会触发（并非本实验特有）；此前用 vLLM 跑 GLM-7B 一类模型、只有 webchat、且都是**短请求**，未出现问题。
- 电源历史：原装 HP DC 圆孔外置电源只有 200 W；已按网络方案更换 Alienware 300 W，故障仍出现。说明限制不止于电源额定功率，**主板 12V 主/辅稳压（VRM）供电链路本身更可能是瓶颈**。
- 方向性判断（未经仪器测量）：Strata 会同时压榨 GPU、CPU 与 SSD（RAM 常驻 experts、CPU 计算未驻留 experts、SSD 流式读取 n-gram 表），比短请求 webchat 更接近持续满载，因而更容易触发该供电故障。

结论：本机目前无法用于稳定可靠的高性能或长时间推理（A2000 持续负载会触发主板供电故障）。iLO 建议收集 Active Health System 日志并开 HPE support case。

## 推理实验

- [Strata + Swift 1.5 实验记录（2026-09-28）](./microserver-gen10plus-strata.md)

## 访问凭据

SSH 登录说明及 iLO 凭据见私有仓 `infra-private/docs/inventory/guanggu/microserver-gen10plus.md`。
