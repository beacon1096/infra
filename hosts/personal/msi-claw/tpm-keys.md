# MSI Claw 8+ AI TPM Keys

TPM-backed cryptographic keys for this device.

## Hardware

- **TPM Chip**: Intel TPM 2.0 (Lunar Lake)
- **Device**: `/dev/tpm0`, `/dev/tpmrm0`
- **Service**: `tpm2-abrmd.service`

## SSH Key

Current checked-in key reference for this device:

**Generated**: 2026-04-19
**Type**: ECDSA (NIST P-256)
**Public Key**:
```
ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBFGl/aWJSeQ2utkndM7mOOmp9FHdvj4ViG1RQGiHLhB36HWXBvQuxYzdlYTniwVTZLf6qutvOpLh/kVTwaHWuj0= beacon@msi-claw
```

**Fingerprint**: `SHA256:9KCb79EAlEfbaXHN4DqNCfMeo/k48p8fnQaKcwAAy2Q`

**Recommended files**:
- `~/.ssh/id_ecdsa.tpm` - TPM-backed private key file for `ssh-tpm-agent`
- `~/.ssh/id_ecdsa.pub` - SSH public key

**Attributes**: `fixedtpm|fixedparent|sensitivedataorigin|userwithauth|sign`

## Age Key (sops-nix)

- **Expected path**: `/var/lib/sops-nix/age-plugin-tpm.txt`
- **Plugin**: `age-plugin-tpm`
- **Expected public key**: `age1tpm1qf4rtzpw8hstpu093mdn3n0w2mtx30fmuykw5zukytgegj9rlztacruqnh5`

## Regeneration

### SSH Key
```bash
tpm-ssh-keygen id_ecdsa
systemctl --user restart ssh-tpm-agent
ssh-add -L
```

### Age Key
```bash
sudo install -d -m 0700 /var/lib/sops-nix
sudo age-plugin-tpm --generate -o /var/lib/sops-nix/age-plugin-tpm.txt
sudo chmod 600 /var/lib/sops-nix/age-plugin-tpm.txt
sudo age-plugin-tpm -y --tpm-recipient /var/lib/sops-nix/age-plugin-tpm.txt
```

## Configuration

- System: `/etc/nixos/modules/nixos/tpm-ssh.nix`, `tpm-sops.nix`
- User: `/etc/nixos/modules/home/tpm-ssh.nix`
- Host: `/etc/nixos/hosts/personal/msi-claw/configuration.nix`
- Structured keys record: `/etc/nixos/hosts/personal/msi-claw/tpm-keys.nix`
