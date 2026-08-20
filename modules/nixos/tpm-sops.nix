# TPM-backed sops-nix integration via age-plugin-tpm.
{ pkgs, ... }:

{
  environment.systemPackages = [ pkgs.age-plugin-tpm ];

  sops.age = {
    # age-plugin-tpm identities are ordinary age identity files whose
    # contents start with AGE-PLUGIN-TPM-... and reference TPM-sealed key
    # material. Generate one with:
    #   age-plugin-tpm --generate -o /var/lib/sops-nix/age-plugin-tpm.txt
    #   age-plugin-tpm -y --tpm-recipient /var/lib/sops-nix/age-plugin-tpm.txt
    keyFile = "/var/lib/sops-nix/age-plugin-tpm.txt";
    plugins = [ pkgs.age-plugin-tpm ];
    sshKeyPaths = [ ];
  };

  sops.gnupg.sshKeyPaths = [ ];

  systemd.tmpfiles.rules = [
    "d /var/lib/sops-nix 0700 root root -"
    "z /var/lib/sops-nix 0700 root root -"
    "z /var/lib/sops-nix/age-plugin-tpm.txt 0600 root root -"
  ];
}
