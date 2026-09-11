# Jetson AGX Thor: UEFI settings

## Snapshot

Read-only inspection on 2026-09-11, after the initial NixOS installation and
display handoff fix. Firmware reports `39.2.0-gcid-45755727`; the installed
JetPack NixOS configuration uses L4T 39.2.1 and Linux 6.8.12.

Linux exposed 71 variables under `/sys/firmware/efi/efivars`, including 20 in the
NVIDIA public-variable namespace. Payloads were read for 16 NVIDIA settings or
status variables and five standard UEFI variables. This is an observed snapshot,
not a declaration that every setting below is required by NixOS.

The raw inventory is not committed: it includes device-specific metadata.
Addresses, device identifiers, EFI device paths, certificates, authentication
data and opaque payloads are omitted here.

## NVIDIA variables

GUID: `781e084c-a330-417c-b678-38e696380cb9`.

Hex payloads below exclude the four-byte efivarfs attribute header. Multibyte
integers are little-endian. Attribute `0x07` means nonvolatile, boot-service and
runtime access; `0x06` means boot-service and runtime access without nonvolatile
storage.

| Variable | Attributes | Payload | Interpretation |
| --- | --- | --- | --- |
| `SocDisplayHandoffMode` | `0x07` | `00` | Never: reset the display on UEFI exit |
| `SocDisplayHandoffMethod` | `0x07` | `01` | simplefb |
| `BoardRecoveryBoot` | `0x07` | `00` | Recovery boot not requested |
| `DgpuDtEfifbSupport` | `0x07` | `00` | dGPU EFIFB support in Device Tree mode disabled |
| `NewDeviceHierarchy` | `0x07` | `01` | Add new boot options at the top of the boot order |
| `L4TDefaultBootMode` | `0x07` | `01 00 00 00` | Direct; this is the L4T launcher setting, not the currently selected EFI loader |
| `IpmiNetworkBootMode` | `0x07` | `00` | IPv4 for IPMI-requested network boot; does not itself enable network boot |
| `MemoryTestControl` | `0x07` | 32 zero bytes | Test level Ignore, with all remaining fields zero |
| `RootfsStatusSlotA` | `0x07` | `00 00 00 00` | NVIDIA status: normal |
| `RootfsStatusSlotB` | `0x07` | `00 00 00 00` | NVIDIA status: normal |
| `RootfsRetryCountMax` | `0x06` | `03 00 00 00` | Retry count 3 |
| `RootfsRedundancyLevel` | `0x06` | `00 00 00 00` | Recorded value 0; no NixOS root-filesystem redundancy is implied |
| `BootChainFwCurrent` | `0x06` | `00 00 00 00` | Current firmware boot-chain value 0 |
| `ServerPowerControlSetting` | `0x07` | `00` | Enum selects 50 ms input-power-capping window; applicability to this board was not verified |
| `ExposeRtRtcService` | `0x07` | `00` | Recorded value 0; behavior not independently verified |
| `SystemFwVersions` | `0x06` | `00 02 27 00 00 02 27 00` | Raw version data retained without an assumed structure |

The other four NVIDIA variables were enumerated but their payloads were not
read: `TegraPlatformSpec`, `TegraPlatformCompatSpec`, `ProfilerBase` and
`ProfilerSize`.

NVIDIA rootfs status variables are firmware bookkeeping; they do not establish
the presence of an A/B NixOS installation. This host uses one ext4 root partition.

## Standard UEFI variables

GUID: `8be4df61-93ca-11d2-aa0d-00e098032b8c`.

| Variable | Attributes | Value | Interpretation |
| --- | --- | --- | --- |
| `SecureBoot` | `0x06` | `00` | Secure Boot disabled |
| `SetupMode` | `0x06` | `01` | Setup Mode active |
| `BootCurrent` | `0x06` | `09 00` | `Boot0009`: Linux Boot Manager, using systemd-boot |
| `BootOrder` | `0x07` | `0009,0008,0007,0004,0003,0002,0001,0000,0005,0006` | Observed order; identifiers are local to this firmware installation |
| `Timeout` | `0x07` | `05 00` | Firmware boot-menu timeout: 5 seconds |

## Display handoff and visibility limits

The working configuration uses Device Tree mode. Before the fix,
`SocDisplayHandoffMode` was `01` (Always), which means **never reset**, not
always reset. Changing it to `00` (Never) allowed the NVIDIA DRM driver to
provide a 2560×1440 framebuffer and a visible login prompt. The method remained
`01` (simplefb). These are firmware settings; the NixOS host module does not
automatically write these variables.

No separately named ACPI/Device Tree selection variable appeared in the Linux
inventory. Device Tree boot was confirmed from the running system instead.

Not all UEFI menu settings are visible after boot. The r39.2 form definitions
declare settings such as `QuickBootEnabled`, `EnablePcieInOS`, `SerialPortConfig`,
`KernelCommandLine`, `AcpiTimerEnabled`, `UefiShellEnabled`,
`EnabledPcieNicTopology` and `LockAllVarsConfig` without runtime access. Their
absence from Linux does not mean they are disabled. Inspecting these requires
the UEFI setup interface or a suitable pre-boot tool.

## References

- [NVIDIA r39.2 variable types and display enum values](https://github.com/NVIDIA/edk2-nvidia/blob/r39.2/Silicon/NVIDIA/Include/NVIDIAConfiguration.h)
- [NVIDIA r39.2 UEFI form definitions and variable attributes](https://github.com/NVIDIA/edk2-nvidia/blob/r39.2/Silicon/NVIDIA/Drivers/NvidiaConfigDxe/NvidiaConfigHii.vfr)
- [NVIDIA r39.2 additional configuration constants](https://github.com/NVIDIA/edk2-nvidia/blob/r39.2/Silicon/NVIDIA/Drivers/NvidiaConfigDxe/NvidiaConfigHii.h)
- [NVIDIA r39.2 menu help text](https://github.com/NVIDIA/edk2-nvidia/blob/r39.2/Silicon/NVIDIA/Drivers/NvidiaConfigDxe/NvidiaConfigHii.uni)
