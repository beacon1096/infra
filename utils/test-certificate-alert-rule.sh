#!/usr/bin/env bash
# Unit-test WanxiangCertificateExpiringSoon against synthetic certificate series
# with promtool. No cluster, no network, no credentials.
set -euo pipefail
cd "$(dirname "$0")/.."
PROMTOOL=$(nix build --no-link --print-out-paths nixpkgs#prometheus.cli | head -1)/bin/promtool
PYENV=$(NIX_PATH=nixpkgs=$(nix eval --raw nixpkgs#path) \
  nix build --no-link --print-out-paths --impure --expr 'with import <nixpkgs> {}; python3.withPackages (p: [ p.pyyaml ])')
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
"$PYENV/bin/python3" utils/extract-certificate-rule.py "$WORK/certificate-rules.yaml"
cp utils/test-certificate-alert-rule.yaml "$WORK/"
"$PROMTOOL" test rules "$WORK/test-certificate-alert-rule.yaml"
