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

## 推理实验：Strata + Swift 1.5

实验目的：验证 [Strata](https://github.com/Niko1221/Strata)（Qwen3.8-Flash-Next 125B MoE 的本地推理框架）在本机的实际可用性。

- 环境：Ubuntu 24.04 容器 + 手动 GPU 直通（`/dev/nvidia*`）。上游只发布 Windows 预编译引擎，Linux 需自行用 CUDA 13.0 编译引擎（sm_86）。模型 Swift 1.5 `IQ2_XS`，32K 上下文，纯文本。
- 资源占用：约 35 GiB RAM、10.7 GiB VRAM；native pack 约 1.4 GiB，expert cache 3999/24576 slots（约 16% experts 常驻显存）。
- 吞吐：约 **7–10 tokens/s**（引擎自报一次 181 tokens / 18.6 s = 9.7 tok/s）。
- 瓶颈分析：
  - **CPU 主导**：仅约 16% experts 驻留 12 GiB 显存，其余由 CPU（CC150，8C/16T，仅 AVX2）计算。参考基准为 6 核 Ryzen 7600（AVX-512）+ RTX 5070；AVX2 回流加上较弱的 GPU 是主要差距来源。
  - **磁盘次要**：28.8 GB 的 n-gram / PLE 表按 token 随机读取，受 SATA SSD 延迟影响；模型加载约 0.93 GiB/s。生成稳态下磁盘开销仅量级个位数百分比，不是主因。
  - 结论：稳态吞吐瓶颈为 **CPU(AVX2) + 12 GiB 显存 ≫ SATA RAID5 磁盘**。
- 善后：实验后已删除容器、移除 8080 的 tailscale serve 转发，主机恢复原状；模型数据（约 72 GB，`/home/beacon/strata`）暂留，待供电问题处理后决定去留。

## 访问凭据

SSH 登录说明及 iLO 凭据见私有仓 `infra-private/docs/inventory/guanggu/microserver-gen10plus.md`。
