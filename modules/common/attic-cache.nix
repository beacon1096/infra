# Attic binary cache configuration
# Enables using the self-hosted Attic cache for faster builds
{ lib, config, pkgs, ... }:

let
  atticHost = "nix.beaco.works";
  atticCacheUrl = "https://${atticHost}/nix-fleet";
  atticSecretFile = ../../secrets/shared/attic.yaml;
  atticSecretExists = builtins.pathExists atticSecretFile;
in
{
  sops.secrets = lib.mkIf atticSecretExists {
    "nix/attic/token" = {
      sopsFile = atticSecretFile;
      owner = "root";
      group = if pkgs.stdenv.isDarwin then "staff" else "root";
      mode = "0400";
    };
  };

  sops.templates = lib.mkIf atticSecretExists {
    "nix-attic.netrc" = {
      owner = "root";
      group = "wheel";
      mode = "0440";
      content = ''
        machine ${atticHost}
          login token
          password ${config.sops.placeholder."nix/attic/token"}
      '';
    };
  };

  nix.settings = {
    # Add Attic cache as a substituter
    # This will be used before trying to build locally
    substituters = [
      # Self-hosted Attic cache (built by CI)
      atticCacheUrl
    ];

    # Public key for Attic cache verification
    # This key is used to verify that packages from the cache are authentic
    trusted-public-keys = [
      # Attic cache public key (nix-fleet)
      "nix-fleet:SFqnNaEmgQD5T6UUi6eWOrjBNe+6oPaDo0/1rH9u1ok="
    ];
  } // lib.optionalAttrs atticSecretExists {
    # Nix daemon cache pulls happen in the root/daemon context, so the
    # credential must be available as a machine-level runtime file.
    netrc-file = config.sops.templates."nix-attic.netrc".path;
  };
}
