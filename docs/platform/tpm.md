# TPM 托管的密钥与 Secret

各主机的 TPM 密钥细节保存在对应主机目录；这里记录跨主机的共用流程。

## 共用模块

- `modules/nixos/tpm-ssh.nix` 与 `modules/home/tpm-ssh.nix`：配置 `ssh-tpm-agent` 和 TPM 托管的 SSH 密钥。
- `modules/nixos/tpm-sops.nix`：通过 `/var/lib/sops-nix/age-plugin-tpm.txt` 将 `age-plugin-tpm` 接入 sops-nix。

## 主机登记流程

在 TPM 已可用的目标主机上，以有管理权限的账户执行。更新密钥前先确认旧身份仍可用于解密现有 Secret；更换收件人时必须重新加密受影响文件。

```bash
sudo systemctl enable --now tpm2-abrmd
tpm-ssh-keygen id_ecdsa
systemctl --user restart ssh-tpm-agent

sudo install -d -m 0700 /var/lib/sops-nix
sudo age-plugin-tpm --generate -o /var/lib/sops-nix/age-plugin-tpm.txt
sudo chmod 600 /var/lib/sops-nix/age-plugin-tpm.txt
sudo chown root:root /var/lib/sops-nix/age-plugin-tpm.txt

sudo age-plugin-tpm -y --tpm-recipient /var/lib/sops-nix/age-plugin-tpm.txt
```

将输出的公开收件人同步到 `.sops.yaml` 及相关 `.nix` 记录，然后对每个受影响的 Secret 执行 `sops updatekeys`。例如：

```bash
cd /etc/nixos
nix shell nixpkgs#sops --command sops updatekeys -y secrets/personal/git.yaml secrets/shared/*.yaml
```

确认 TPM SSH 公钥、sops 身份文件与主机构建：

```bash
SSH_AUTH_SOCK="$XDG_RUNTIME_DIR/ssh-tpm-agent.sock" ssh-add -L
sudo ls -l /var/lib/sops-nix/age-plugin-tpm.txt
sudo nixos-rebuild switch --flake .#<host>
```

## 已登记主机

- `surface-pro-8`：`hosts/personal/surface-pro-8/tpm-keys.nix` 与 `tpm-keys.md`。
- `msi-claw`：`hosts/personal/msi-claw/tpm-keys.nix` 与 `tpm-keys.md`；通过 `modules/nixos/tpm-sops.nix` 使用 TPM age 身份。

这些是仓库记录，不是实时在线状态；各主机的具体策略以主机配置为准。
