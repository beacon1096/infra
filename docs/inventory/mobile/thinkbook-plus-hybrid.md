# ThinkBook Plus G5 Hybrid

主机名：`thinkbook-plus-hybrid`。NixOS 配置位于 `hosts/personal/thinkbook-plus-hybrid/`。

这台设备由 Intel Meteor Lake 笔记本底座和可拆卸 Android 平板组成，平板兼作笔记本内屏。保留 Windows/NixOS 双系统；Windows 上的 Lenovo Hybrid Center 提供与平板的额外集成功能。

## 安装与磁盘布局

NixOS 于 2026-08-18 安装。原有 GPT 和 Windows 分区均保留，仅格式化原 `Data` 分区 `/dev/nvme0n1p4`。

| 分区 | 用途 | 文件系统 | NixOS 挂载点 |
| --- | --- | --- | --- |
| `p1` | 共用 EFI 系统分区 | FAT32 | `/boot` |
| `p2` | Microsoft 保留分区 | Microsoft reserved | 不挂载 |
| `p3` | Windows | NTFS | 不挂载 |
| `p4` | NixOS | Btrfs，标签 `nixos` | `/`、`/home` |
| `p5` | Windows 恢复分区 | NTFS | 不挂载 |

Btrfs 子卷为根目录 `@` 和家目录 `@home`，没有 swap。32 GiB 内存不足以稳妥执行大型本地 C++ 构建，应使用远程 builder。安装时以 `-j22` 构建 PrusaSlicer/Bambu Studio 曾导致 OOM；将 Nix 并行任务和每任务核心数都限制为 4 后构建成功。

systemd-boot 与 Windows Boot Manager 共存于同一 ESP；未手动修改时，固件默认启动项仍为 Windows。

## Hybrid Tab 显示切换

键盘 Smart Key 映射为 `Insert`。按下可在硬件层面把平板从 PC 显示输入切到 Android；切回 PC 时，Hyprland 可能因 Intel DRM page flip 未完成而黑屏：

```text
Cannot commit when a page-flip is awaiting
```

DRM 接口仍显示 `connected` 和 `enabled`，因此不能当作普通热插拔处理。平板切回 PC 时，ELAN 触摸屏（`04f3:42ea`）会经 USB 重新连接。主机专属 udev 规则据此启动 `hybrid-display-resume.service`，对 `eDP-1` 切换 DPMS 以恢复画面。开机时触摸屏可能先于 Hyprland 枚举，服务应把 `/run/user/1000/hypr` 不存在视为正常情况。

从其他终端或 SSH 手动恢复：

```sh
export XDG_RUNTIME_DIR=/run/user/1000
export HYPRLAND_INSTANCE_SIGNATURE="$(basename "$(find /run/user/1000/hypr -mindepth 1 -maxdepth 1 -type d | head -1)")"
hyprctl dispatch dpms off eDP-1
sleep 1
hyprctl dispatch dpms on eDP-1
```

内屏为 2880×1800 Samsung eDP 面板，缩放比例 `1.5`，逻辑工作区 1920×1200。F5/F6 亮度调节有效，但视觉变化可能不明显。

## 指纹识别

电源键集成 Goodix MOC 指纹设备 `27c6:6512 Goodix USB2.0 MISC`，由 `libfprint`/`fprintd` 支持。`services.fprintd.enable = true` 也将指纹认证加入生成的 PAM 配置，包括 greetd、sudo 和 polkit。右手食指于 2026-08-19 登记并验证。

登记、验证、列出或删除指纹：

```sh
sudo fprintd-enroll -f right-index-finger beacon
sudo fprintd-verify -f right-index-finger beacon
sudo fprintd-list beacon
sudo fprintd-delete beacon
```

## 无线网络与固件

Intel AX211 在 NixOS 安装环境中可能不自动加载 `iwlwifi`。主机配置将它显式加入 `boot.kernelModules`；加载后接口为 `wlp0s20f3`，扫描正常。驱动加载时可能报告 ACPI 路径 `\\_SB.PC00.CNVW.IFUN.RSTY` 错误，但无线网卡仍可正常初始化。

Lenovo 固件还包含错误或重复的 ACPI 对象。启动和设备状态切换时可能出现重复 USB `_UPC`/`_PLD`、Wi-Fi 初始化缺少 `CNVW.IFUN.RSTY`、充电/散热方法缺少 `HEC.DPTF.FCHG`，以及 ELAN 触摸屏重连时短暂的 USB `error -71`。这些消息未阻止无线、触摸、图形或正常启动。没有明确功能故障前，不应猜测性添加 `acpi_osi` 覆盖；优先检查 Lenovo 固件更新。

## 图形驱动

Meteor Lake GPU（`8086:7d55`）目前使用 `i915`。内核虽提供 `xe`，但未绑定此设备。试用 `xe` 需要：

```text
i915.force_probe=!7d55 xe.force_probe=7d55
```

这应保持为非默认实验配置。`xe` 与 `i915` 共享 Intel 显示/KMS 代码，仅切换驱动不能推定会修复 Hybrid Tab 的 page-flip 问题。

## 密钥与 SSH Agent

设备从 `/etc/ssh/ssh_host_ed25519_key` 派生 sops age 身份。公开收件人已列入 `secrets/shared` 和 `secrets/personal` 的创建规则。新增或更换主机 SSH 密钥后，须更新收件人并重新加密相应文件，再部署；否则 Home Manager 等依赖密钥的服务将因渲染后的 Secret 缺失而失败。

默认 SSH Agent 是 `ssh-tpm-agent`。设备有一把封装于 Intel Meteor Lake TPM 的 ECDSA P-256 密钥，公钥指纹为 `SHA256:IlhPzUzLgAgXJVBmlLvYV2onYc2zna1NfB5Dq1I2ATY`。公钥位于 `~/.ssh/id_ecdsa.pub`，绑定硬件的私钥包装文件位于 `~/.ssh/id_ecdsa.tpm`；公开元数据见 `hosts/personal/thinkbook-plus-hybrid/tpm-keys.nix`。检查当前 Agent：

```sh
SSH_AUTH_SOCK="$XDG_RUNTIME_DIR/ssh-tpm-agent.sock" ssh-add -L
```
