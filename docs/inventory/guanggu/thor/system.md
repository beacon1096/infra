# Thor 系统与固件

[Thor 推理与模型实验](../../../inference/thor/README.md)

设备为 Jetson AGX Thor T5000（SM110）。具体模型的运行时及性能观察见[模型实验索引](../../../inference/thor/README.md#模型与引擎)。

## 声明式配置

- [主机配置](../../../../hosts/personal/fixed/thor/configuration.nix)：用户、Hyprland、Tailscale、SSH 和网络设置。
- [硬件配置](../../../../hosts/personal/fixed/thor/hardware-configuration.nix)：本机的启动和存储配置。
- [推理服务](../../../../hosts/personal/fixed/thor/inference.nix)：SGLang 启动参数、内存门槛、健康检查，以及 `inference/` 下的运行时补丁与 SHA256 清单。
- [风扇控制](../../../../hosts/personal/fixed/thor/fan-control.nix)：接管懒猫守护进程并在推理前锁定 Performance 档位。
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

## RTL8127 MAC 与 DHCP（2026-10-04）

在一台采用 RTL8127 有线网卡的算力舱上，NixOS 每次启动可能获得不同的 DHCP 地址，即使 NetworkManager 已配置 `cloned-mac-address=permanent`。本节仅保留可复用的调查结论，不包含现场 MAC、IP、SSH 公钥、设备序列号或私有运维路径。

### 驱动的 permanent 不一定是出厂地址

本次 NixOS 使用 Realtek `r8127 11.015.00-NAPI`，官方系统使用同版 `11.015.00-NAPI-PTP`。源码中的 `rtl8127_get_mac_address()`：

1. 读取当前 MAC 寄存器 `MAC0`。
2. 使用备份寄存器 `0x19e0/0x19e4` 覆盖前面读取的六个字节。
3. 若结果不是有效单播地址，生成随机 MAC。
4. 将选定地址写入当前 MAC 寄存器，并复制到 `org_mac_addr` 和 `dev->perm_addr`。

因此，`ethtool -P` 可能返回本次启动生成的随机地址。NetworkManager 的 `permanent` 策略会使用这个值，不能保证跨启动稳定。DHCP 服务端按客户端 MAC 匹配的固定分配仍然有效，但新 MAC 不再匹配原预留。

### 热启动、冷启动与官方系统对照

使用仅增加日志、不改变地址选择逻辑的诊断模块，记录首次 BAR 映射、OOB 退出、PLL 上电、硬件初始化、两次网卡复位及 EEPROM 检测前后的寄存器。以下为去掉设备身份和非关键字段后的摘录：

```text
stage=bar-mapped mac0=00:00:00:00:00:00 backup=00:00:00:00:00:00 d2=04
stage=before-exit-oob mac0=00:00:00:00:00:00 backup=00:00:00:00:00:00 d2=04
stage=after-hw-reset mac0=00:00:00:00:00:00 backup=00:00:00:00:00:00 d2=04
reset_poll_remaining=100 timeout=0
eeprom_probe=unsupported-d2
eeprom_result type=0 length=0
```

NixOS 普通重启和正常关机、移除外部供电后冷启动的结果一致：首次读取时两组 MAC 已为零，后续初始化没有恢复地址，两次复位均未报告超时。本次并不是复位首次清掉有效 MAC，也不是选取备份值时丢弃了一个有效的当前 MAC。

`rtl_eeprom.c` 在 `0xD2 & 0x04` 非零时直接跳过其支持的串行 EEPROM 读取路径，源码中的 `EEPROM_TWSI` 处理被注释。因此 `eeprom_type=0`、`eeprom_len=0` 不能证明 EEPROM 为空或不存在。

另一次热启动进入官方系统后，原厂驱动同样记录全零地址、随机回退，备份寄存器仍为零；但 NetworkManager 随后通过 `stable` 策略设置稳定的活动 MAC，取得对应 DHCP 预留。官方系统的稳定联网是软件策略的结果，不是恢复出厂 MAC 的证据。此次未对官方系统另做断电冷启动测试。

最早快照仍发生在 PCI 设备启用之后，不能覆盖固件、PCI 核心或平台上电过程。是否存在已烧录但没有装载、或无法通过当前驱动读取的出厂地址，仍需厂商支持的 NVM 读取方法确认；不应据此尝试写 EEPROM。

### 可选诊断构建

[驱动包](../../../../packages/r8127/default.nix)提供默认关闭的 `macDiagnostics` 参数，[诊断补丁](../../../../packages/r8127/mac-diagnostics.patch)将版本标记为 `-MAC-DIAG`。检查点日志仅在网卡注册前输出，避免在运行中的复位恢复流程持续增加 MMIO 读取和日志。

```sh
nix build .#packages.aarch64-linux.r8127-mac-diagnostics --no-link
sudo journalctl -b -k -o short-monotonic --grep='r8127-mac-diag'
```

此输出针对当前公开 Thor 配置的内核构建，不一定匹配已部署系统。实际试验必须核对内核构建和模块符号版本，不能只比较 `uname -r`；保留正常启动项，优先使用一次性诊断启动，而不是在线卸载网卡驱动。新增读取和日志也可能影响时序，诊断结果应结合对照实验解释。

### 稳定地址与双系统 SSH

可在 NixOS 的声明式有线 profile 中写入一次选定的本地管理单播 MAC，不再依赖驱动的 `permanent` 值。例如：

```nix
networking.networkmanager.ensureProfiles.profiles."Wired connection 1".ethernet.cloned-mac-address =
  "02:00:00:00:00:01";
```

该 MAC 仅为文档示例，部署时应选取所在二层网络内唯一的地址，并为其建立 DHCP 预留。也可使用 NetworkManager 的 `stable` 策略，但结果依赖本机状态及 profile 输入，跨系统不保证得到同一地址。

双系统可分别保留自己的稳定 MAC、DHCP 地址和 SSH 主机密钥。连接不同地址，或通过不同的 `HostKeyAlias` 区分主机身份，避免同一 IP 在切系统后对应另一套公钥。迁移时应通过可信渠道核对并更新旧的 `known_hosts` 条目，而不是关闭主机密钥检查。

本次以明确固定的 NixOS 软件 MAC 和官方系统已有的 stable MAC 分配两个独立地址，分别启动验证 DHCP 与严格 SSH 校验后，恢复正常 NixOS 和推理服务。旧回退 MAC 的固定分配取消，避免继续占用地址。

## 参考资料

- [NVIDIA r39.2 变量类型与显示模式枚举](https://github.com/NVIDIA/edk2-nvidia/blob/r39.2/Silicon/NVIDIA/Include/NVIDIAConfiguration.h)
- [NVIDIA r39.2 UEFI 表单定义与变量属性](https://github.com/NVIDIA/edk2-nvidia/blob/r39.2/Silicon/NVIDIA/Drivers/NvidiaConfigDxe/NvidiaConfigHii.vfr)
- [NVIDIA r39.2 其他配置常量](https://github.com/NVIDIA/edk2-nvidia/blob/r39.2/Silicon/NVIDIA/Drivers/NvidiaConfigDxe/NvidiaConfigHii.h)
- [NVIDIA r39.2 菜单帮助文本](https://github.com/NVIDIA/edk2-nvidia/blob/r39.2/Silicon/NVIDIA/Drivers/NvidiaConfigDxe/NvidiaConfigHii.uni)
