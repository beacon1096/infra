# Public metadata for TPM-backed keys on ThinkBook Plus G5 Hybrid Station.
{
  tpm = {
    manufacturer = "INTC";
    model = "Meteor Lake";
    version = "2.0";
    firmware = "1.59";
  };

  ssh = {
    generated = "2026-08-19";
    algorithm = "ECDSA";
    curve = "NIST P-256";
    publicKey = "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBOsCCVuM5tqk6gfn9j7qDeaaN36ZY18Z8Q9ARViMSywNc5HD5ujV3ctD9x71q/yEC6M5liIheUOkILOzJ5E0Gdo= beacon@thinkbook-plus-hybrid";
    fingerprint = "SHA256:IlhPzUzLgAgXJVBmlLvYV2onYc2zna1NfB5Dq1I2ATY";
    files = {
      publicKey = "~/.ssh/id_ecdsa.pub";
      privateKey = "~/.ssh/id_ecdsa.tpm";
    };
  };
}
