# TPM-backed Keys and Secrets

This repository keeps per-host TPM key details under each host directory,
and this document records the shared workflow.

## Shared modules

- `modules/nixos/tpm-ssh.nix`
- `modules/home/tpm-ssh.nix`
- `modules/nixos/tpm-sops.nix`

`tpm-ssh.nix` provides `ssh-tpm-agent` and TPM-backed SSH key handling.
`tpm-sops.nix` wires `sops-nix` to `age-plugin-tpm` using
`/var/lib/sops-nix/age-plugin-tpm.txt`.

## Standard host enrollment flow

Run on the target host as a privileged user where TPM is already available.

```bash
# 1) Ensure TPM runtime is present and services are running.
sudo systemctl enable --now tpm2-abrmd

# 2) Generate TPM-backed SSH key for the host account.
tpm-ssh-keygen id_ecdsa
systemctl --user restart ssh-tpm-agent

# 3) Create/replace the TPM sealed age identity for sops.
sudo install -d -m 0700 /var/lib/sops-nix
sudo age-plugin-tpm --generate -o /var/lib/sops-nix/age-plugin-tpm.txt
sudo chmod 600 /var/lib/sops-nix/age-plugin-tpm.txt
sudo chown root:root /var/lib/sops-nix/age-plugin-tpm.txt

# 4) Print the recipient/key to sync into .sops.yaml and .nix records.
sudo age-plugin-tpm -y --tpm-recipient /var/lib/sops-nix/age-plugin-tpm.txt

# 5) Rotate secret recipients (for every affected secret file).
cd /etc/nixos
nix shell nixpkgs#sops --command sops updatekeys -y secrets/personal/git.yaml secrets/shared/*.yaml
```

### Helpful checks

- Verify SSH TPM keys are loaded:
  `SSH_AUTH_SOCK="$XDG_RUNTIME_DIR/ssh-tpm-agent.sock" ssh-add -L`
- Verify `sops` identity path is readable during activation:
  `sudo ls -l /var/lib/sops-nix/age-plugin-tpm.txt`
- Rebuild host after changes:
  `sudo nixos-rebuild switch --flake .#<host>`

## Current host registrations

- `hosts/personal/surface-pro-8`
  - TPM key record: `hosts/personal/surface-pro-8/tpm-keys.nix`
  - TPM doc: `hosts/personal/surface-pro-8/tpm-keys.md`

- `hosts/personal/msi-claw`
  - TPM key record: `hosts/personal/msi-claw/tpm-keys.nix`
  - TPM doc: `hosts/personal/msi-claw/tpm-keys.md`

## Notes on host-specific policy

- `surface-pro-8` uses the same TPM-backed modules and keeps its own host key record.
- `msi-claw` now uses `sops.age.keyFile = "/var/lib/sops-nix/age-plugin-tpm.txt"`
  via `modules/nixos/tpm-sops.nix`.
