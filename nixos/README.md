# NixOS cloud server inventory

This directory records the nine cloud-server configurations requested during onboarding. It is a declaration-only inventory derived from the `nix-fleet` repository, not a claim that every host was reachable or currently powered on.

## Source

- Repository: `nix-fleet`
- Ref: `main`
- Observed commit: `e381b7f`
- NixOS targets: `flake.nix` → `nixosConfigurations`
- SSH aliases and addresses: `hosts/agents/coding/home.nix`
- Host-specific configuration: `hosts/server/<name>/configuration.nix`

The listed targets are `ark`, `shuttle`, `courier`, `cygnus`, `navi`, `glacier`, `speicher`, `octo`, and `flint`. The `nixbuilder-01` through `nixbuilder-03` targets are intentionally excluded from this cloud VPS inventory because the flake describes them as Harvester build/runner nodes.

## SSH access

The current coding-agent SSH configuration defines all nine aliases with login user `beacon` and port `2233`. Host-key verification is enabled through the managed local SSH configuration. This repository records the endpoint and access convention only; private keys and known-host material remain local and are not copied here.

This pass checked the NixOS declarations and local alias definitions only. It did not open SSH sessions or verify live reachability.

The structured list is in [`cloud-servers.yaml`](./cloud-servers.yaml).
