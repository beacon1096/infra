# ThinkBook Plus Hybrid 切回 PC 后黑屏：诊断与恢复

2026-11-14，Linux 6.18.38、Hyprland 0.55.4、Aquamarine 0.11.0。设备入口见 [ThinkBook Plus G5 Hybrid](thinkbook-plus-hybrid.md#hybrid-tab-显示切换)。

## 已确认的故障过程

- 安卓切回 PC、触摸屏 USB 重连后，自动恢复服务启动。第一次 DPMS off 返回 `ok`，随后的 on 发生 Hyprland IPC 超时，服务退出码为 6；这不能证明 off 已在硬件层完成。
- 同期 i915 报 `flip_done timed out`、`DSB 0 timed out waiting for idle`，随后出现 CRTC、connector、plane 的 `commit wait timed out` 和 `pipe_off wait timed out`。
- 稍后 DPMS off/on 均可返回 `ok`，Hyprland 显示 `dpmsStatus=true`，但内核仍为 `connected / disabled / Off`，`intel_backlight` 的 `brightness=160`、`actual_brightness=0`、`bl_power=4`。
- 普通 DPMS 开关、monitor disable/enable、写入 `bl_power=0` 均未恢复。仅切换虚拟终端会短暂亮屏，随后再次黑屏；Aquamarine 日志包含 `Cannot commit when a page-flip is awaiting`。
- 模拟内屏断开、重连后恢复为 `connected / enabled / On`、`actual_brightness=160`、`bl_power=0`。原 Hyprland PID 和应用会话保留，连续观察 30 秒没有新增内核显示错误，用户确认画面持续正常。

## 保留桌面和应用的恢复步骤

从 SSH 或另一个终端执行。先用 `loginctl list-sessions` 确认图形桌面位于 `tty1`，且 `tty2` 没有其他用户会话；下面的 `chvt 1`、`chvt 2` 对应这两个终端。DRM 的 card 编号可能变化，因此按 `eDP-1` 查找内屏。

```sh
bash <<'SH'
set -e
sudo -v
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
shopt -s nullglob
panels=(/sys/class/drm/card*-eDP-1/status)
test "${#panels[@]}" -eq 1
panel_status=${panels[0]}
restore() {
  set +e
  printf 'detect\n' | sudo -n tee "$panel_status" >/dev/null
  sudo -n chvt 1
}
trap restore EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

printf 'off\n' | sudo -n tee "$panel_status" >/dev/null
sudo -n chvt 2
sleep 1
sudo -n chvt 1
sleep 2
hyprctl -i 0 monitors all

printf 'detect\n' | sudo -n tee "$panel_status" >/dev/null
sudo -n chvt 2
sleep 1
sudo -n chvt 1
sleep 3
hyprctl -i 0 monitors all
SH
```

第一次 `monitors all` 应不再列出 `eDP-1`，第二次应重新出现。该过程临时强制 connector 为断开状态，再恢复自动探测；退出处理也会恢复 `detect` 并切回桌面终端。

核对内核输出和背光，并持续观察实际画面，避免把短暂亮屏当作恢复：

```sh
cat /sys/class/drm/card*-eDP-1/{status,enabled,dpms}
cat /sys/class/backlight/intel_backlight/{brightness,actual_brightness,bl_power}
```

正常应为 `connected`、`enabled`、`On`，`bl_power=0`，且实际亮度与非零的设定亮度相符。

## 原因与证据边界

可以确认此次故障同时涉及 i915 显示提交超时，以及 Aquamarine 未清掉的待完成 page flip 状态。DPMS 请求、Hyprland 的逻辑状态与内核硬件状态随后出现不一致。

源码解释了为什么原有恢复方式失效：

1. Aquamarine 在成功提交需要 page flip 完成事件的帧后设置 `isPageFlipPending`，正常在完成回调中清除。该状态残留时，重新启用并配置输出或提交新画面会返回失败；停用输出仍可能成功。这能解释为何 DPMS off 后无法再次 on。[Atomic 提交](https://github.com/hyprwm/aquamarine/blob/cd8321eba285e3cce50c50f19d5174a0b2567297/src/backend/drm/impl/Atomic.cpp#L461)、[完成回调](https://github.com/hyprwm/aquamarine/blob/cd8321eba285e3cce50c50f19d5174a0b2567297/src/backend/drm/DRM.cpp#L1044)、[提交限制](https://github.com/hyprwm/aquamarine/blob/cd8321eba285e3cce50c50f19d5174a0b2567297/src/backend/drm/DRM.cpp#L1900)。
2. Hyprland 的 DPMS 操作先改软件状态，再尝试硬件提交；提交失败会记录日志并安排重试，但 dispatcher 不向 IPC 调用者返回该失败。重复请求相同软件状态还会提前返回。因此 `ok` 和 `dpmsStatus=true` 可以与内核 `Off` 同时存在。off 的渐黑动画也意味着 `ok` 可早于硬件停用。[dispatcher](https://github.com/hyprwm/Hyprland/blob/a0136d8c04687bb36eb8a28eb9d1ff92aea99704/src/config/shared/actions/ConfigActions.cpp#L1200)、[DPMS 实现](https://github.com/hyprwm/Hyprland/blob/a0136d8c04687bb36eb8a28eb9d1ff92aea99704/src/helpers/Monitor.cpp#L2251)。
3. 单独切换 VT 会恢复显示模式，但不保证清除待完成标志。强制 connector 断开后，VT 恢复时的重新探测会销毁旧 output，其析构会清掉该标志；恢复探测并再次切换 VT 才能创建新 output。这与本次保留 Hyprland 进程的成功恢复一致。[VT 恢复](https://github.com/hyprwm/aquamarine/blob/cd8321eba285e3cce50c50f19d5174a0b2567297/src/backend/drm/DRM.cpp#L378)、[output 析构](https://github.com/hyprwm/aquamarine/blob/cd8321eba285e3cce50c50f19d5174a0b2567297/src/backend/drm/DRM.cpp#L1782)。

内核超时的最初触发原因仍未确定。Linux 6.18.38 的 DSB（Display State Buffer）用于批量执行显示寄存器操作，超时只能证明该队列未正常完成；`current head=0x100` 本身不足以确定是哪条指令、哪个硬件环节失效。硬件切换过程中显示时序或完成事件丢失仍是推测，需要复现时的 DSB 命令转储及 DRM 事件记录才能进一步定位。[内核 DSB 实现](https://github.com/gregkh/linux/blob/v6.18.38/drivers/gpu/drm/i915/display/intel_dsb.c#L869)。

本机已经通过 `i915.enable_psr=0` 禁用 PSR，不能把本次故障直接归为 PSR 未关闭。也不能仅凭相同错误字符串，断言它对应某个其他 Intel 平台的 DSB 缺陷。
