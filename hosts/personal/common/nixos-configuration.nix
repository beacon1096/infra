# Personal — shared NixOS system configuration for all Beacon's NixOS machines
#
# This is the NixOS counterpart to configuration.nix (which is darwin-specific).
# Both share modules/common (nix settings, packages, sing-box).
{
  pkgs,
  config,
  lib,
  ...
}:

let
  atticPushHosts = [
    "msi-claw"
    "surface-pro-8"
    "m920x"
    "microserver-gen10plus"
  ];
  atticPushEnabled = builtins.elem config.networking.hostName atticPushHosts;
  atticPushSecretFile = ../../../secrets/personal/attic-push.yaml;
  atticUpload = pkgs.writeShellScriptBin "attic-upload-system" ''
    if ! XDG_CONFIG_HOME=/run/secrets-rendered/attic-upload \
      ${lib.getExe pkgs.attic-client} push nix-fleet /run/current-system; then
      echo "warning: system switched successfully, but Attic upload failed" >&2
    fi
  '';
in
{
  imports = [
    ../../../modules/common
    ../../../modules/common/remote-builder.nix
    # ../../../modules/common/nix-mirror-cn.nix  # Temporarily disabled due to corrupt narinfo files
    ../../../modules/nixos
    ../../../modules/nixos/tailscale-userspace.nix
  ];

  beacoworks.remoteBuilder.enableArm = true;

  # Extra packages (base packages are in modules/common/packages.nix)
  sops.secrets."nix/attic/push-token" = lib.mkIf atticPushEnabled {
    sopsFile = atticPushSecretFile;
    owner = "root";
    group = "root";
    mode = "0400";
  };

  sops.templates."attic-upload-config" = lib.mkIf atticPushEnabled {
    path = "/run/secrets-rendered/attic-upload/attic/config.toml";
    owner = "root";
    group = "root";
    mode = "0400";
    content = ''
      default-server = "fleet"

      [servers.fleet]
      endpoint = "https://nix.beaco.works"
      token = "${config.sops.placeholder."nix/attic/push-token"}"
    '';
  };

  environment.systemPackages = lib.mkIf atticPushEnabled [
    atticUpload
  ];

  # Immutable users — fully declarative, no passwd command
  users.mutableUsers = false;

  # Primary user
  users.users.beacon = {
    isNormalUser = true;
    description = "Beacon Zhang";
    extraGroups = [
      "wheel"
      "networkmanager"
      "video"
      "input"
      "tss"
    ];
    hashedPassword = "$6$tN01Y0uoc31ThXBq$hGi3IKw1aHC17Qz9VQUIsurSNb2lMjCxUt6AtxIiqgpomYYDVnMWiCsuPd0tEZvgsFZWqhz1cMTUvYb6AJCSu.";
    openssh.authorizedKeys.keys = [
      # YubiKey authentication subkey (GPG → SSH)
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGzeQXE4+OHN5k3aVjsJ4rfW4Luy5W+ckm0gh2bbkpmM cardno:20_499_295"
      # Active SSH key from Surface Pro 8
      "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBHu3LcgN91fDQjnd6rlZj+wJSoB5MPOWBoLh176bzu8yO5sQCpAJ8MtUVZbE35LJvxwtDMl1blodBpeskXasOR0= beacon@surface-pro-8"
      # Active SSH key from MSI Claw 8+ AI
      "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBFGl/aWJSeQ2utkndM7mOOmp9FHdvj4ViG1RQGiHLhB36HWXBvQuxYzdlYTniwVTZLf6qutvOpLh/kVTwaHWuj0= beacon@msi-claw"
      # TPM-backed SSH key from ThinkBook Plus Hybrid
      "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBOsCCVuM5tqk6gfn9j7qDeaaN36ZY18Z8Q9ARViMSywNc5HD5ujV3ctD9x71q/yEC6M5liIheUOkILOzJ5E0Gdo= beacon@thinkbook-plus-hybrid"
      # TPM-backed SSH key from m920x
      "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBC3fP4DxeRnXRpwehi0En0e2n/HpOsdF1hf33NfgbKzkWSBecjJlix5xldfSKk6t378lMJ4yMcQVrwvrLHQwYFg= beacon@m920x"
      # TPM-backed SSH key from microserver-gen10plus
      "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBJGwIGaHwdhEQ8QvZhXoArtJ4I44fxsFoihasONWAIrBBJWlKcyfwWOTFPelUil0hfI/ENzTdgrtxcVIukqqstQ= beacon@microserver-gen10plus-tpm"
      # Trusted coding agent runtime
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICDP4oDTGH/Pk+6BPAcxxAsLTxxYU7mIz1Qfv4RX1FH7 Agent @ Beacoworks"
    ];
  };

  # Root — SSH key only, no password
  users.users.root = {
    hashedPassword = "!";
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGzeQXE4+OHN5k3aVjsJ4rfW4Luy5W+ckm0gh2bbkpmM cardno:20_499_295"
      # Active SSH key from MSI Claw 8+ AI
      "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBFGl/aWJSeQ2utkndM7mOOmp9FHdvj4ViG1RQGiHLhB36HWXBvQuxYzdlYTniwVTZLf6qutvOpLh/kVTwaHWuj0= beacon@msi-claw"
      # TPM-backed SSH key from m920x
      "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBC3fP4DxeRnXRpwehi0En0e2n/HpOsdF1hf33NfgbKzkWSBecjJlix5xldfSKk6t378lMJ4yMcQVrwvrLHQwYFg= beacon@m920x"
      # TPM-backed SSH key from microserver-gen10plus
      "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBJGwIGaHwdhEQ8QvZhXoArtJ4I44fxsFoihasONWAIrBBJWlKcyfwWOTFPelUil0hfI/ENzTdgrtxcVIukqqstQ= beacon@microserver-gen10plus-tpm"
    ];
  };

  sops.secrets."personal/git/email" = {
    sopsFile = ../../../secrets/personal/git.yaml;
  };

  sops.templates."git-personal.inc" = {
    owner = "beacon";
    mode = "0400";
    content = ''
      [user]
          email = ${config.sops.placeholder."personal/git/email"}
    '';
  };

  environment.etc."git-personal.inc".source = config.sops.templates."git-personal.inc".path;
}
