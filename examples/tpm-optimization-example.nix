# Example configuration for enabling TPM optimizations
# Add this to your host configuration.nix or import the modules

{ config, lib, pkgs, ... }:

{
  # Import the TPM and SSH integration module
  imports = [
    # System-level TPM configuration
    ../modules/nixos/tpm-ssh.nix
  ];

  # Optional: Additional optimizations for daily use

  # 1. Use TPM for sudo authentication (instead of password)
  security.pam.services.sudo = {
    # TPM-based authentication for sudo
    text = lib.mkAfter ''
      auth sufficient pam_tpm2.so
    '';
  };

  # 2. Secure automatic login with TPM attestation
  # services.getty.autologinUser = "beacon";  # Only if TPM unseals successfully

  # 3. Use TPM to store WiFi passwords securely
  networking.networkmanager = {
    enable = true;
    # Store WiFi passwords in TPM-sealed format
    # This requires additional setup with clevis
  };

  # 4. TPM-based secret management with sops-nix
  sops = {
    # Derive age key from TPM instead of SSH host key
    age.sshKeyPaths = lib.mkForce [ ];
    age.keyFile = "/var/lib/sops-nix/tpm-age.key";

    # Generate TPM-sealed age key on activation
    # This would be created with: age-keygen | clevis encrypt tpm2 '{}' > /var/lib/sops-nix/tpm-age.key.jwe
  };

  # 5. Secure boot with TPM measurements
  boot.loader.systemd-boot = {
    enable = true;
    # Sign unified kernel images
    consoleMode = "max";
    # Enroll secure boot keys (requires additional setup)
    # secureBoot = true;
  };

  # 6. Use TPM for LUKS encryption (systemd-cryptenroll)
  # Automatically unlock encrypted drives with TPM
  boot.initrd = {
    systemd.enable = true;
    # Example for root partition encryption with TPM
    # luks.devices."cryptroot" = {
    #   device = "/dev/nvme0n1p2";
    #   # Enroll TPM2 key: sudo systemd-cryptenroll --tpm2-device=auto /dev/nvme0n1p2
    #   crypttabExtraOpts = [ "tpm2-device=auto" "tpm2-pcrs=0+7" ];
    # };
  };

  # 7. Performance optimizations for TPM operations
  boot.kernelParams = [
    "tpm_tis.interrupts=0"  # Fix for some TPM chips
    "random.trust_cpu=on"   # Trust CPU RNG (in addition to TPM RNG)
  ];

  # 8. Additional security tools that work well with TPM
  environment.systemPackages = with pkgs; [
    # Password manager with TPM support
    pass
    gopass

    # YubiKey manager (works alongside TPM)
    yubikey-manager

    # Secure communication
    age
    sops

    # TPM-based attestation
    # tpm2-attestation

    # Measure boot (for secure boot chain)
    sbctl
  ];

  # 9. SSH server hardening when using TPM client keys
  services.openssh.settings = {
    PermitRootLogin = "no";
    PasswordAuthentication = false;
    KbdInteractiveAuthentication = false;

    # Only allow strong algorithms
    Ciphers = [
      "chacha20-poly1305@openssh.com"
      "aes256-gcm@openssh.com"
    ];

    KexAlgorithms = [
      "sntrup761x25519-sha512@openssh.com"
      "curve25519-sha256"
    ];

    # Require TPM-backed or hardware keys
    PubkeyAuthOptions = "verify-required";
  };

  # 10. Audit TPM usage
  services.auditd = {
    enable = true;
    rules = [
      # Audit TPM device access
      "-w /dev/tpm0 -p rwxa -k tpm_access"
      "-w /dev/tpmrm0 -p rwxa -k tpm_resource_manager"
    ];
  };
}

# Home-Manager configuration example
# Add to your home.nix or user configuration:
#
# {
#   imports = [
#     ../modules/home/tpm-ssh.nix
#   ];
#
#   # User-specific TPM settings
#   home.sessionVariables = {
#     SSH_AUTH_SOCK = "$HOME/.ssh/ssh-tpm-agent.sock";
#   };
# }