# 懒猫 AI Pod（LC-X5 / Jetson T5000）

## 硬件与系统（2026-09-23 SSH 采集）

| 项目 | 已知信息 |
| --- | --- |
| 产品 | 懒猫算力舱 LC-X5（官方应用名称：Lazycat AI Pod） |
| 系统识别平台 | NVIDIA Jetson AGX Thor Developer Kit；设备树兼容项 `nvidia,p4071-0000+p3834-0008`、`nvidia,p3834-0008`、`nvidia,tegra264` |
| CPU | 14 核 / 14 线程 ARM Neoverse-V3AE，最高报告频率 2.601 GHz |
| 内存 | NVIDIA T5000 规格为 128 GB、256-bit LPDDR5X；Linux `MemTotal` 为 128825804 kB（约 122.9 GiB） |
| GPU | NVIDIA GB10B（Jetson AGX Thor）；驱动 595.78，CUDA 13.2；`nvidia-smi` 不报告显存容量 |
| 存储 | KIOXIA-EXCERIA PRO SSD，约 1.8 TiB，承载当前系统；Lexar SSD ARES PRO 1TB，约 953.9 GiB |
| 高速网络 | NVIDIA SoC 集成 MGBE（非独立 PCIe 网卡），4 个接口（`mgbe0_0`–`mgbe3_0`）；QSFP28 支持 4×25GbE、理论聚合最高 100Gbps；采集时四接口均无链路 |
| 有线网络 | Realtek RTL8127 10GbE 控制器；当前链路协商为 2.5Gb/s |
| 无线网络 | Realtek RTL8852CE 802.11ax 控制器 |
| 当前系统 | NixOS 26.05，hostname `thor`，Linux `6.8.12`，aarch64 |

2026-09-23 使用 `dmidecode` 采集 SMBIOS：type 16 报告内存阵列上限 128 GiB 和 `Single-bit ECC`，但没有 type 17 内存设备记录；因此 LPDDR5X 类型来自 NVIDIA T5000 官方规格，而非 SMBIOS 核实，SMBIOS 的 ECC 字段也不代表已验证运行时纠错。NVIDIA 的 [Jetson Thor 规格](https://www.nvidia.com/en-au/autonomous-machines/embedded-systems/jetson-thor/)列明 T5000 为 128 GB LPDDR5X、开发套件有 QSFP28（4×25GbE）；设备树、PCI、CPU、内存、NVMe 和网卡数据由本机采集。设备序列号及 SSH 访问信息保留在 private 仓 `infra-private/docs/inventory/guanggu/lazycat-aipod/README.md`。
