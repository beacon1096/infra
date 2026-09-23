# Thor 系统与固件

[Thor 推理与模型实验](../../../inference/thor/README.md)

设备为 Jetson AGX Thor T5000（SM110）。具体模型的运行时及性能观察见[模型实验索引](../../../inference/thor/README.md#模型与引擎)。

## 声明式配置

- [主机配置](../../../../hosts/personal/fixed/thor/configuration.nix)：用户、Hyprland、Tailscale、SSH 和网络设置。
- [硬件配置](../../../../hosts/personal/fixed/thor/hardware-configuration.nix)：本机的启动和存储配置。
- [懒猫温控检查](lzc-thermal.md)：AI Pod 界面、后端、设备代理和风扇守护进程的控制链，以及 NixOS 接管边界。

以上文件描述公开的声明式配置。下列固件信息是带日期的只读快照，不表示各项数值均为 NixOS 所需设置。

## 固件快照

2026-09-11，在初次安装 NixOS 并修复显示交接后进行了只读检查。固件报告 `39.2.0-gcid-45755727`；已安装的 JetPack NixOS 配置使用 L4T 39.2.1 和 Linux 6.8.12。

Linux 在 `/sys/firmware/efi/efivars` 下暴露 71 个变量，其中 20 个属于 NVIDIA 公开变量命名空间。读取了 16 个 NVIDIA 设置或状态变量，以及 5 个标准 UEFI 变量的值。

原始清单含设备特有元数据，因此未提交；下文省略地址、设备标识、EFI 设备路径、证书、认证数据及无法解释的原始数据。

## NVIDIA 变量

GUID：`781e084c-a330-417c-b678-38e696380cb9`。

下表十六进制值不含 efivarfs 的 4 字节属性头；多字节整数采用小端序。属性 `0x07` 表示非易失且可在启动服务和运行时访问；`0x06` 表示可在启动服务和运行时访问，但不具备非易失属性。

| 变量 | 属性 | 值 | 解读 |
| --- | --- | --- | --- |
| `SocDisplayHandoffMode` | `0x07` | `00` | Never：退出 UEFI 时重置显示 |
| `SocDisplayHandoffMethod` | `0x07` | `01` | `simplefb` |
| `BoardRecoveryBoot` | `0x07` | `00` | 未请求恢复启动 |
| `DgpuDtEfifbSupport` | `0x07` | `00` | Device Tree 模式下未启用独显 EFIFB 支持 |
| `NewDeviceHierarchy` | `0x07` | `01` | 将新启动项放到启动顺序前部 |
| `L4TDefaultBootMode` | `0x07` | `01 00 00 00` | Direct：L4T 启动器设置，不代表当前选择的 EFI 加载器 |
| `IpmiNetworkBootMode` | `0x07` | `00` | IPMI 请求网络启动时使用 IPv4；该值本身不会启用网络启动 |
| `MemoryTestControl` | `0x07` | 32 个零字节 | 测试级别为 Ignore，其余字段为零 |
| `RootfsStatusSlotA` | `0x07` | `00 00 00 00` | NVIDIA 状态：正常 |
| `RootfsStatusSlotB` | `0x07` | `00 00 00 00` | NVIDIA 状态：正常 |
| `RootfsRetryCountMax` | `0x06` | `03 00 00 00` | 最多重试 3 次 |
| `RootfsRedundancyLevel` | `0x06` | `00 00 00 00` | 记录值为 0；不能据此推定 NixOS 根文件系统有冗余 |
| `BootChainFwCurrent` | `0x06` | `00 00 00 00` | 当前固件启动链记录值为 0 |
| `ServerPowerControlSetting` | `0x07` | `00` | 枚举值对应 50 ms 输入功率限制窗口；未核实该设置是否适用于本板 |
| `ExposeRtRtcService` | `0x07` | `00` | 记录值为 0；未独立验证行为 |
| `SystemFwVersions` | `0x06` | `00 02 27 00 00 02 27 00` | 仅保留原始版本数据，不臆测字段结构 |

另有四个 NVIDIA 变量只完成枚举，未读取内容：`TegraPlatformSpec`、`TegraPlatformCompatSpec`、`ProfilerBase`、`ProfilerSize`。

NVIDIA 根文件系统状态变量属于固件账本，不能证明本机采用 A/B NixOS 安装。此主机只有一个 ext4 根分区。

## 标准 UEFI 变量

GUID：`8be4df61-93ca-11d2-aa0d-00e098032b8c`。

| 变量 | 属性 | 值 | 解读 |
| --- | --- | --- | --- |
| `SecureBoot` | `0x06` | `00` | 安全启动关闭 |
| `SetupMode` | `0x06` | `01` | 处于设置模式 |
| `BootCurrent` | `0x06` | `09 00` | `Boot0009`：通过 systemd-boot 启动 Linux Boot Manager |
| `BootOrder` | `0x07` | `0009,0008,0007,0004,0003,0002,0001,0000,0005,0006` | 当时观察到的启动顺序；编号只对本次固件安装有效 |
| `Timeout` | `0x07` | `05 00` | 固件启动菜单等待 5 秒 |

## 显示交接与可见性限制

可工作的配置采用 Device Tree 模式。修复前 `SocDisplayHandoffMode` 为 `01`（Always），含义是**始终不重置显示**，而不是始终重置。改为 `00`（Never）后，NVIDIA DRM 驱动能够提供 2560×1440 帧缓冲和可见的登录提示。`SocDisplayHandoffMethod` 仍为 `01`（`simplefb`）。这些是固件设置，NixOS 主机模块不会自动写入这些变量。

Linux 变量清单中没有单独命名的 ACPI/Device Tree 选择变量；Device Tree 启动是从运行中的系统确认的。

并非所有 UEFI 菜单设置都能在启动后读取。r39.2 的表单定义包含 `QuickBootEnabled`、`EnablePcieInOS`、`SerialPortConfig`、`KernelCommandLine`、`AcpiTimerEnabled`、`UefiShellEnabled`、`EnabledPcieNicTopology` 和 `LockAllVarsConfig` 等不带运行时访问权限的设置。Linux 下看不到不代表它们已关闭；需要在 UEFI 设置界面或通过合适的预启动工具检查。

## 参考资料

- [NVIDIA r39.2 变量类型与显示模式枚举](https://github.com/NVIDIA/edk2-nvidia/blob/r39.2/Silicon/NVIDIA/Include/NVIDIAConfiguration.h)
- [NVIDIA r39.2 UEFI 表单定义与变量属性](https://github.com/NVIDIA/edk2-nvidia/blob/r39.2/Silicon/NVIDIA/Drivers/NvidiaConfigDxe/NvidiaConfigHii.vfr)
- [NVIDIA r39.2 其他配置常量](https://github.com/NVIDIA/edk2-nvidia/blob/r39.2/Silicon/NVIDIA/Drivers/NvidiaConfigDxe/NvidiaConfigHii.h)
- [NVIDIA r39.2 菜单帮助文本](https://github.com/NVIDIA/edk2-nvidia/blob/r39.2/Silicon/NVIDIA/Drivers/NvidiaConfigDxe/NvidiaConfigHii.uni)
