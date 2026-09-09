# TPM-backed cryptographic keys for Surface Pro 8
# Private keys are hardware-bound and cannot be extracted from TPM
{
  # TPM Hardware Info
  tpm = {
    manufacturer = "INTC"; # Intel
    model = "TGL"; # Tiger Lake
    version = "2.0";
    firmware = "1.38";
  };

  # SSH Key
  ssh = {
    generated = "2026-04-07";
    algorithm = "ECDSA";
    curve = "NIST P-256";

    publicKey = "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBHu3LcgN91fDQjnd6rlZj+wJSoB5MPOWBoLh176bzu8yO5sQCpAJ8MtUVZbE35LJvxwtDMl1blodBpeskXasOR0= beacon@surface-pro-8";

    fingerprint = "SHA256:BUMzmPBVeiJ8JEbSL3oWMJ8VlHH0JYkQTHTOATXo0Vc";

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
    generated = "2026-04-07";
    algorithm = "age";
    curve = "X25519";

    publicKey = "age1tpm1q0009mzte44x9a6rer8zf34249r0n6h7up6tz4jpht97nwsjk8x378wj4cl";

    files = {
      identity = "/var/lib/sops-nix/age-plugin-tpm.txt";
    };

    plugin = "age-plugin-tpm";
  };
}
