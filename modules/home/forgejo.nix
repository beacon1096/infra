# Forgejo — token-based `tea` login for personal hosts.
#
# Personal devices share one beacon1096 PAT, which sops-nix decrypts to
# /run/secrets/personal/forgejo/token (owner beacon). The token is never
# written to the Nix store: this module only hands it to `tea login add`
# during activation, and records a hash so a rotated token is re-applied.
#
# OAuth is deliberately not used: Forgejo keeps one OAuth grant per
# (user, application) and rotates refresh tokens, so several machines sharing
# the built-in `tea` client id cannot each keep a valid token.
{ config, lib, osConfig, pkgs, ... }:

let
  secretName = "personal/forgejo/token";
  secret = lib.attrByPath [ "sops" "secrets" secretName ] null osConfig;
  secretPath = if secret == null then null else secret.path;
  server = "https://forgejo.beaco.works";
  loginName = "forgejo";
  marker = "${config.home.homeDirectory}/.config/tea/.forgejo-token-sha256";
  sha256sum = "${pkgs.coreutils}/bin/sha256sum";
  cut = "${pkgs.coreutils}/bin/cut";
in
{
  home.packages = [ pkgs.tea ];

  home.activation.forgejoTeaLogin = lib.mkIf (secretPath != null)
    (lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      token_file=${lib.escapeShellArg secretPath}
      if [ -z "''${DRY_RUN_CMD:-}" ]; then
        if [ -r "$token_file" ]; then
          token_hash="$(${sha256sum} "$token_file" | ${cut} -d' ' -f1)"
          if [ ! -f ${lib.escapeShellArg marker} ] || [ "$(cat ${lib.escapeShellArg marker})" != "$token_hash" ]; then
            token="$(tr -d '\n' < "$token_file")"
            run ${pkgs.tea}/bin/tea login delete ${loginName} >/dev/null 2>&1 || true
            if run ${pkgs.tea}/bin/tea login add \
              --name ${loginName} \
              --url ${server} \
              --token "$token" \
              --no-version-check; then
              run ${pkgs.tea}/bin/tea login default ${loginName} >/dev/null 2>&1 || true
              run mkdir -p "$(dirname ${lib.escapeShellArg marker})"
              printf '%s' "$token_hash" > ${lib.escapeShellArg marker}
            else
              echo "forgejo: tea login add failed, will retry on next activation" >&2
            fi
          fi
        else
          echo "forgejo: token is not readable at $token_file" >&2
        fi
      fi
    '');
}
