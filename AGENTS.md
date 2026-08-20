You are an experienced, pragmatic software engineering AI agent. Keep changes
minimal and preserve the repository's public/private boundary.

# Project overview

This public monorepo contains Beacon's NixOS and nix-darwin fleet configuration,
Talos/Kubernetes/Flux configuration, and infrastructure inventories. Secrets
are managed with SOPS.

# Repository boundary

- SOPS ciphertext may be committed; plaintext credentials and decrypted
  outputs may not.
- Private cloud-host definitions and private edge/proxy topology belong only in
  `infrastructure/infra-private`.
- Do not add private-repository files, host inventories, or service topology to
  this repository, even if their credentials would be encrypted.
- Keep the Nix flake at the repository root. Do not add `infra-private` as a
  submodule.

# Important paths

- `flake.nix`: public host definitions and package outputs.
- `hosts/`, `modules/`, `packages/`: Nix fleet source.
- `secrets/`: encrypted material only.
- `taichu/`, `wanxiang/`: cluster configuration and inventories.
- `.forgejo/workflows/`: Forgejo Actions workflows and release gate.

# Validation

Run commands from the repository root.

- Broad evaluation: `nix flake show --all-systems`
- Targeted NixOS build: `nix build .#nixosConfigurations.<host>.config.system.build.toplevel`
- macOS build: `nix build .#darwinConfigurations.beacon-mac-mini-m4.system`
- Shell validation: `bash -n utils/<script>.sh`
- Formatting: `nix fmt` when available, otherwise `nixpkgs-fmt` on touched Nix files.

Do not commit generated `result*` links or local credentials. Review every diff
for private host data before publishing.
