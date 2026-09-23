# YubiKey 触摸提示音

GnuPG 没有稳定的外部钩子能准确指出 `gpg-agent` 或 `scdaemon` 何时开始等待 YubiKey 触摸。对短小的签名、解密操作，可以用“`gpg` 运行超过短暂延迟”作为提醒用户的近似信号，而不是把它当成确切的触摸事件。

实现分两层：高优先级 `gpg` 包装器从固定的 Nix store 路径调用真正的 GnuPG；提示助手等待一秒，若子进程仍在运行，就播放声音并发送桌面通知。包装器须透传参数、标准输入输出、信号和退出状态。真实二进制取自 `${pkgs.gnupg}/bin/gpg`，避免递归调用包装器。

这也覆盖通过 `PATH` 调用 `gpg` 的 Git、SOPS 等程序。不要包装 `ssh`：成功建立的交互式 SSH 会话通常持续超过一秒，无法靠进程时长区分认证等待和已建立会话。

## 提示助手

PipeWire 桌面上的 `pw-play` 使用当前默认音频输出。助手可合成一段短 PCM 提示音，不必另带音频资源，并通过用户 D-Bus 会话发送桌面通知。音频不可用时，应退回终端响铃和文字提示。运行时依赖应显式声明：

```nix
yubikeyNotification = pkgs.writeShellApplication {
  name = "with-yubikey-notification";
  runtimeInputs = with pkgs; [
    coreutils
    pipewire
    python3
    systemd
  ];
  text = builtins.readFile ./with-yubikey-notification.sh;
};
```

助手应一直存活到被观察的 GPG 进程结束，以便清理时关闭桌面通知。

## GPG 包装器

延迟提示的核心逻辑如下；生产包装器还须捕获 `INT`/`TERM`，将取消信号传给 GPG，停止提示助手，并保留 `SIGINT` 的惯例退出码 130 等状态。

```bash
delay="${YUBIKEY_NOTIFY_DELAY:-1}"

/nix/store/...-gnupg/bin/gpg "$@" <&0 &
child_pid=$!

(
  sleep "$delay"
  if kill -0 "$child_pid" 2>/dev/null; then
    with-yubikey-notification \
      bash -c 'while kill -0 "$1" 2>/dev/null; do sleep 0.2; done' \
      _ "$child_pid"
  fi
) &
notifier_pid=$!

status=0
wait "$child_pid" || status=$?
kill -TERM "$notifier_pid" 2>/dev/null || true
wait "$notifier_pid" 2>/dev/null || true
exit "$status"
```

仅在 Linux 桌面环境把助手和高优先级包装器装入 Home Manager：

```nix
home.packages = lib.optionals pkgs.stdenv.isLinux [
  yubikeyNotification
  (lib.hiPrio gpgWithYubikeyNotification)
];
```

单次调用可调整提示阈值：

```bash
YUBIKEY_NOTIFY_DELAY=2 gpg --sign artifact
```

## 限制与验证

进程时长只是操作启发式，不证明 YubiKey 正在等待触摸。散列大文件、等待 PIN、启动 `gpg-agent`/`scdaemon` 或读取慢速输入都可能误触发。对小型 Git 签名和 SOPS 文件，这类延迟通常值得提醒用户；通知应说“密码学操作仍在等待，请检查闪烁的密钥”，不要宣称操作失败。

先运行 `gpg --version`，确认快速命令不提示；再运行以下不签名、不改变密钥环的延迟测试：

```bash
(sleep 2) | gpg --import
```

约一秒后应响起提示；随后 GPG 以 `no valid OpenPGP data found` 结束，不导入任何密钥。还需确认无效选项保留原退出状态，`Ctrl-C` 能结束两层进程。
