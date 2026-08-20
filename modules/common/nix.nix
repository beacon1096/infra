# Nix daemon settings — shared across darwin and NixOS
{ lib, ... }:

{
  nix.settings = {
    experimental-features = [ "nix-command" "flakes" ];

    # Allow admin users to use all nix features
    # darwin uses @admin; NixOS uses @wheel (overridden in modules/nixos/default.nix)
    trusted-users = [ "root" "@admin" ];

    # Use substituter caches during remote builds
    builders-use-substitutes = true;

    # nix-community cachix (useful globally, not a CN mirror)
    substituters = [
      "https://nix-community.cachix.org"
      "https://codex-desktop-linux.cachix.org"
    ];
    trusted-public-keys = [
      "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
      "codex-desktop-linux.cachix.org-1:nX/xy6AdK9hQE24A8ALGjkCKj2ObFmcnemiL5Cid4nk="
    ];

    extra-substituters = [
      "https://cache.numtide.com"
    ];
    extra-trusted-public-keys = [
      "niks3.numtide.com-1:DTx8wZduET09hRmMtKdQDxNNthLQETkc/yaX7M4qK0g="
    ];
  };

  # auto-optimise-store corrupts the Nix store on darwin; use periodic optimisation instead
  nix.optimise.automatic = true;

  # Garbage collection — remove generations older than 7 days weekly
  nix.gc = {
    automatic = lib.mkDefault true;
    options = lib.mkDefault "--delete-older-than 7d";
  };

  nixpkgs.config.allowUnfree = true;

  # Timezone
  time.timeZone = lib.mkDefault "Asia/Shanghai";

  # Hugging Face mirror (useful in mainland China)
  environment.variables = {
    HF_ENDPOINT = "https://hf-mirror.com";
  };
}
