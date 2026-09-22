# 懒猫微服本体

运行懒猫微服服务的设备。以下硬件与系统信息于 2026-09-23 通过 SSH 只读采集。

## 硬件与系统

| 项目 | 已知信息 |
| --- | --- |
| 主机名 | `lzcbox-2fab9c94` |
| 主板 | SMBIOS 报告厂商 `LNKS`、型号 `LC2892`；系统厂商与产品名称字段为通用 `Default string` |
| CPU | 13th Gen Intel Core i5-13500H；12 核 / 16 线程，最高报告频率 4.7 GHz |
| 内存 | SMBIOS 报告 16 GiB DDR5 SO-DIMM，标称 5600 MT/s、当前配置 5200 MT/s；两条内存设备记录中一条为空。Linux `MemTotal` 为 16094372 kB（约 15.35 GiB） |
| ECC | SMBIOS 报告内存阵列纠错类型为 None，模块总线宽度与数据宽度均为 64 bit；未单独验证运行时纠错能力 |
| 显示 | Intel Raptor Lake-P 集成 UHD Graphics，驱动 `i915` |
| 存储 | 两块 NVMe：WD_BLACK SN7100 500GB（系统识别 465.8 GiB）、KIOXIA-EXCERIA SSD（465.8 GiB） |
| 有线网络 | Intel Ethernet Controller I226-V，驱动 `igc`；采集时接口 `enp2s0` 链路为 1 Gbps |
| 无线网络 | Intel Wi-Fi 6 AX210，驱动 `iwlwifi`；接口 `wlp129s0` |
| 当前系统 | Debian GNU/Linux 12，Linux `6.18.25-x64v3-xanmod1`，x86_64 |

SMBIOS 的主机厂商/产品名为默认占位值，故不据此推断整机零售型号。设备没有安装 `dmidecode`；内存条信息从 `/sys/firmware/dmi/tables` 的 SMBIOS type 16/17 原始记录读取。SMBIOS 字段定义见 [DMTF SMBIOS 规格](https://www.dmtf.org/sites/default/files/standards/documents/DSP0134_3.9.0.pdf)。

## 网络

| 接口 | 地址 |
| --- | --- |
| 有线 | `172.16.20.21` |
| 无线 | `172.16.20.31` |

SSH 访问信息见 private 仓 `infra-private/docs/inventory/guanggu/lazycat-microserver.md`。
