# NixOS cloud server inventory

This directory records the nine cloud-server configurations requested during onboarding plus the always-on `microserver-gen10plus` home/build host. It is primarily a declaration inventory derived from the `nix-fleet` repository; the dated SSH result below is a point-in-time access observation, not a claim about continuous availability.

## Source

- Repository: `nix-fleet`
- Ref: `main`
- Observed commit: `e381b7f`
- NixOS targets: `flake.nix` → `nixosConfigurations`
- SSH aliases and addresses: `hosts/agents/coding/home.nix`
- Host-specific configuration: `hosts/server/<name>/configuration.nix`
- Microserver remote-builder address: `modules/common/remote-builder.nix`

The cloud targets are `ark`, `shuttle`, `courier`, `cygnus`, `navi`, `glacier`, `speicher`, `octo`, and `flint`. The `nixbuilder-01` through `nixbuilder-03` targets are intentionally excluded from this cloud VPS inventory because the flake describes them as Harvester build/runner nodes. `microserver-gen10plus` is tracked separately as an always-on home/build host.

## SSH access

The current coding-agent SSH configuration defines all nine cloud aliases with login user `beacon` and port `2233`. The microserver is declared as the remote builder at Tailscale address `100.121.229.9`, with login user `beacon` and default SSH port `22`; it does not currently have a dedicated coding-agent alias in the checked-in SSH configuration. Host-key verification is enabled for the probe through the host key declared in `nix-fleet`. Private keys and known-host material remain local and are not copied here.

On 2026-08-14, a read-only SSH probe through the local Tailscale socket connected successfully to `microserver-gen10plus` and returned the expected hostname and `beacon` user. Revalidate this observation before automation changes.

The structured list is in [`cloud-servers.yaml`](./cloud-servers.yaml).
