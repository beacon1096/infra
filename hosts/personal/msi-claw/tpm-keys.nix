# TPM-backed cryptographic keys for MSI Claw 8+ AI
# Private keys are hardware-bound and cannot be extracted from TPM.
{
  # TPM Hardware Info
  tpm = {
    manufacturer = "INTC"; # Intel
    model = "Lunar Lake";
    version = "2.0";
  };

  # SSH Key
  ssh = {
    generated = "2026-04-19";
    algorithm = "ECDSA";
    curve = "NIST P-256";

    publicKey = "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBFGl/aWJSeQ2utkndM7mOOmp9FHdvj4ViG1RQGiHLhB36HWXBvQuxYzdlYTniwVTZLf6qutvOpLh/kVTwaHWuj0= beacon@msi-claw";

    fingerprint = "SHA256:9KCb79EAlEfbaXHN4DqNCfMeo/k48p8fnQaKcwAAy2Q";

    attributes = [
      "fixedtpm"
      "fixedparent"
      "sensitivedataorigin"
      "userwithauth"
      "sign"
    ];

    files = {
      publicKey = "~/.ssh/id_ecdsa.pub";
      privateKey = "~/.ssh/id_ecdsa.tpm";
    };
  };

  # Age Key (for sops-nix)
  age = {
    generated = "2026-04-19";
    algorithm = "age";
    curve = "X25519";

    publicKey = "age1tpm1qf4rtzpw8hstpu093mdn3n0w2mtx30fmuykw5zukytgegj9rlztacruqnh5";

    files = {
      identity = "/var/lib/sops-nix/age-plugin-tpm.txt";
    };

    plugin = "age-plugin-tpm";
  };
}
