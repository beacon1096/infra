#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

promtool_path="$(nix path-info "$root#observability-promtool")"
alertmanager_path="$(nix path-info "$root#observability-alertmanager")"
kubectl_path="$(nix path-info "$root#observability-kubectl")"
helm_path="$(nix path-info "$root#observability-helm")"
python_path="$(nix path-info "$root#observability-python")"
pyyaml_path="$(nix path-info "$root#observability-pyyaml")"

python_version="$($python_path/bin/python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
export PATH="$promtool_path/bin:$alertmanager_path/bin:$kubectl_path/bin:$helm_path/bin:$PATH"
export PYTHONPATH="$pyyaml_path/lib/python$python_version/site-packages${PYTHONPATH:+:$PYTHONPATH}"

test_script="${1:-$root/utils/test-observability-prep.py}"
if (( $# > 0 )); then
  shift
fi
exec "$python_path/bin/python3" "$test_script" "$@"
