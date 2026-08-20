# mkSecret — helper for sops-nix nested YAML key access
#
# sops-nix uses "/" as the path separator for nested YAML keys.
# Since the secret attribute name is already in that format,
# we only need to attach the sopsFile. The `key` option defaults
# to the attribute name, so we don't set it explicitly.
#
#   mkSecret sopsFile "sing-box/dns/resolver"
# produces:
#   { sopsFile = ...; }
#
# Usage in modules:
#   mkSecret = (import ../../lib/mk-secret.nix) sopsFile;
#   sops.secrets."sing-box/dns/resolver" = mkSecret "sing-box/dns/resolver";

sopsFile: _path:

{
  inherit sopsFile;
}
