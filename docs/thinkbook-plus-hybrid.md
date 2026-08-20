# ThinkBook Plus G5 Hybrid Station

Host name: `thinkbook-plus-hybrid`

NixOS configuration: `hosts/personal/thinkbook-plus-hybrid/`

This machine combines an Intel Meteor Lake laptop base with a detachable Android
tablet used as the internal display. It dual-boots Windows and NixOS. Windows is
retained because Lenovo's Hybrid Center provides additional integration with the
Android tablet.

## Installation and disk layout

NixOS was installed on 2026-08-18. The original GPT and Windows partitions were
preserved. Only the former `Data` partition, `/dev/nvme0n1p4`, was reformatted.

| Partition | Use | Filesystem | NixOS mount |
| --- | --- | --- | --- |
| `p1` | Shared EFI System Partition | FAT32 | `/boot` |
| `p2` | Microsoft Reserved | Microsoft reserved | not mounted |
| `p3` | Windows | NTFS | not mounted |
| `p4` | NixOS | Btrfs, label `nixos` | `/` and `/home` |
| `p5` | Windows Recovery | NTFS | not mounted |

The Btrfs subvolumes are `@` for `/` and `@home` for `/home`. There is no swap.
Large local C++ builds can exhaust the 32 GiB of RAM, so use a remote builder.
During installation, building PrusaSlicer/Bambu Studio with `-j22` caused an OOM;
limiting Nix to four jobs and four cores per job completed successfully.

systemd-boot installs alongside Windows Boot Manager in the shared ESP. Windows
remains the firmware's default boot entry unless changed manually.

## Hybrid Tab display switching

The keyboard's Smart Key is exposed as `Insert`. Pressing it switches the tablet
from the PC display input to Android in hardware. Pressing it again switches the
tablet back, but Hyprland can leave an Intel DRM page flip pending and display a
black screen:

```text
Cannot commit when a page-flip is awaiting
```

The DRM connector remains `connected` and `enabled`, so this is not represented
as a normal display hotplug. When the tablet returns to PC mode, its ELAN
touchscreen (`04f3:42ea`) reconnects over USB. A host-specific udev rule uses
that event to start `hybrid-display-resume.service`, which cycles DPMS for
`eDP-1` and restores the image.

The service must treat a missing `/run/user/1000/hypr` as normal during boot:
the touchscreen is enumerated before the user starts Hyprland.

Manual recovery from another terminal or SSH session:

```sh
export XDG_RUNTIME_DIR=/run/user/1000
export HYPRLAND_INSTANCE_SIGNATURE="$(basename "$(find /run/user/1000/hypr -mindepth 1 -maxdepth 1 -type d | head -1)")"
hyprctl dispatch dpms off eDP-1
sleep 1
hyprctl dispatch dpms on eDP-1
```

The internal panel is a 2880x1800 Samsung eDP display configured at `1.5` scale,
giving a 1920x1200 logical workspace. F5/F6 brightness control works, although
changes can be visually subtle.

## Fingerprint reader

The power button contains a Goodix MOC reader:

```text
27c6:6512 Goodix USB2.0 MISC
```

It is supported by `libfprint`/`fprintd`. `services.fprintd.enable = true` also
adds fingerprint authentication to the generated PAM configuration, including
greetd, sudo, and polkit. The right index finger was enrolled and verified on
2026-08-19.

Enroll or replace a fingerprint:

```sh
sudo fprintd-enroll -f right-index-finger beacon
sudo fprintd-verify -f right-index-finger beacon
```

List or delete enrolled fingerprints:

```sh
sudo fprintd-list beacon
sudo fprintd-delete beacon
```

## Wireless

The Intel AX211 Wi-Fi device may not load `iwlwifi` automatically in the NixOS
installer. The host configuration explicitly includes `iwlwifi` in
`boot.kernelModules`. Once loaded, the interface is `wlp0s20f3` and scanning
works normally.

Loading the driver can emit an ACPI error involving
`\\_SB.PC00.CNVW.IFUN.RSTY`. The Wi-Fi device still initializes successfully.

## Firmware issues

The Lenovo firmware supplies several malformed or duplicate ACPI objects. Boot
and device transitions can produce errors including:

- duplicate USB `_UPC` and `_PLD` objects;
- missing `CNVW.IFUN.RSTY` while initializing Wi-Fi;
- missing `HEC.DPTF.FCHG` in a charging/thermal method;
- transient USB `error -71` while the ELAN touchscreen reconnects.

These messages have not prevented Wi-Fi, touchscreen, graphics, or normal boot.
Do not add speculative `acpi_osi` overrides without a demonstrated functional
problem. Check Lenovo firmware updates before adding kernel workarounds.

## Graphics driver

The Meteor Lake GPU (`8086:7d55`) currently uses `i915`. The kernel's `xe`
module is available but is not bound to the GPU. Testing `xe` would require:

```text
i915.force_probe=!7d55 xe.force_probe=7d55
```

Keep this experimental and non-default. The `xe` and `i915` drivers share Intel
display/KMS code, so switching drivers is not expected by itself to fix the
Hybrid Tab page-flip issue.

## Secrets

The machine derives its sops age identity from
`/etc/ssh/ssh_host_ed25519_key`. Its public recipient is included in both the
`secrets/shared` and `secrets/personal` creation rules. After adding or replacing
the host SSH key, update the recipient and rekey the affected files before
deploying; otherwise Home Manager, sing-box, and OpenCode Web fail because their
rendered secret files are absent.

## TPM-backed SSH key

`ssh-tpm-agent` is the default SSH agent. The machine has an ECDSA P-256 key
sealed to its Intel Meteor Lake TPM:

```text
SHA256:IlhPzUzLgAgXJVBmlLvYV2onYc2zna1NfB5Dq1I2ATY
```

The public key is `~/.ssh/id_ecdsa.pub`; the hardware-bound private key wrapper
is `~/.ssh/id_ecdsa.tpm`. Public metadata is recorded in
`hosts/personal/thinkbook-plus-hybrid/tpm-keys.nix`. Check the active agent with:

```sh
SSH_AUTH_SOCK="$XDG_RUNTIME_DIR/ssh-tpm-agent.sock" ssh-add -L
```
