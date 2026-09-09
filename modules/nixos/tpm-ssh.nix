# TPM2 support for hosts that use ssh-tpm-agent.
{ pkgs, ... }:

{
  # Enable TPM2 support
  security.tpm2 = {
    enable = true;
    # Enable TPM2 Access Broker & Resource Manager daemon
    abrmd.enable = true;
    # Apply udev rules for TPM device access
    applyUdevRules = true;
  };

  # Install TPM2 tools and utilities
  environment.systemPackages = with pkgs; [
    # Core TPM2 tools
    tpm2-tools
    tpm2-tss

    # SSH TPM Agent - store SSH keys in TPM
    ssh-tpm-agent

    # Additional TPM utilities
    tpm2-abrmd      # TPM2 Access Broker & Resource Manager
    clevis          # Automated decryption framework (TPM2 + Network)
    jose            # JSON Object Signing and Encryption
  ];

  # Environment variables for TPM2 tools
  environment.sessionVariables = {
    # Use the resource manager for TPM access
    TPM2TOOLS_TCTI = "tabrmd";
  };

  # Optional: Secure Boot with TPM2
  # boot.loader.systemd-boot = {
  #   enable = true;
  #   # Sign boot entries with TPM
  #   consoleMode = "max";
  # };

  # Optional: Use TPM2 for LUKS disk encryption
  # boot.initrd.systemd.enable = true;
  # boot.initrd.luks.devices."root" = {
  #   crypttabExtraOpts = [ "tpm2-device=auto" ];
  # };

  # TPM2 eventlog for attestation
  boot.kernelParams = [ "tpm_tis.interrupts=0" ]; # Fix for some TPM chips

  # Security recommendations when using TPM
  security.protectKernelImage = true; # Prevent kernel image replacement
  security.lockKernelModules = false; # Keep false for TPM module loading
}
