# Audible YubiKey Touch Notifications

GnuPG does not expose a stable external hook for the moment when
`gpg-agent` or `scdaemon` starts waiting for YubiKey user presence. A useful
approximation for small signing and decryption operations is to notify when a
`gpg` process is still running after a short delay.

The implementation uses two layers:

1. A `gpg` shim starts the real GnuPG binary from an absolute Nix store path.
2. A notification helper waits one second, then plays a sound and posts a
   desktop notification if the real GPG process is still running.

The shim remains transparent to callers: arguments, standard input and output,
signals, and the GPG exit status are passed through. Because the real binary is
addressed as `${pkgs.gnupg}/bin/gpg`, the shim cannot recursively invoke itself.
Giving the shim higher package priority makes it the `gpg` found in the Home
Manager profile while retaining the original binary as its backend.

This also covers programs such as Git and SOPS when they invoke `gpg` through
`PATH`. It deliberately does not wrap `ssh`: a successful interactive SSH
session normally runs for more than one second, so process duration cannot
distinguish authentication from an established session.

## Notification helper

On a PipeWire desktop, `pw-play` automatically selects the current default
audio sink. The helper can synthesize a short raw PCM tone, avoiding a separate
audio asset, and send a desktop notification over the user's D-Bus session.
If audio is unavailable, it should fall back to a terminal bell and message.

Package the helper with explicit runtime dependencies:

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

The helper should stay alive until the watched GPG process exits so it can
close its desktop notification during cleanup.

## GPG shim

The essential delayed-notification logic is:

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

A production wrapper should also trap `INT` and `TERM`, forward cancellation
to GPG, stop the notifier, and preserve conventional exit statuses such as 130
for `SIGINT`.

Install the helper and a high-priority shim only on Linux desktops:

```nix
home.packages = lib.optionals pkgs.stdenv.isLinux [
  yubikeyNotification
  (lib.hiPrio gpgWithYubikeyNotification)
];
```

The threshold can be changed for one invocation:

```bash
YUBIKEY_NOTIFY_DELAY=2 gpg --sign artifact
```

## Limitations

Process duration is an operational heuristic, not proof that the YubiKey is
waiting for a touch. It can also fire while GPG is:

- hashing a large file before requesting a signature;
- waiting for PIN entry;
- starting `gpg-agent` or `scdaemon`; or
- reading slow input.

For the common case of small Git signatures and SOPS documents, these delays
usually indicate that human attention is useful. Notification text should say
that the cryptographic operation is still waiting and ask the user to touch a
flashing key; it should not claim that the operation failed.

## Testing

First confirm that a fast command completes without notification:

```bash
gpg --version
```

Then exercise the delayed path without signing or changing the keyring:

```bash
(sleep 2) | gpg --import
```

After one second the notification should sound. GPG then exits with `no valid
OpenPGP data found` and imports nothing. Also verify that an invalid option
retains GPG's exit status and that `Ctrl-C` terminates both layers.
