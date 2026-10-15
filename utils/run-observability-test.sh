#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

realise() {
  nix build --no-link --print-out-paths "$root#$1"
}

promtool_path="$(realise observability-promtool)"
alertmanager_path="$(realise observability-alertmanager)"
kubectl_path="$(realise observability-kubectl)"
helm_path="$(realise observability-helm)"
python_path="$(realise observability-python)"
pyyaml_path="$(realise observability-pyyaml)"

python_version="$($python_path/bin/python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
export PATH="$promtool_path/bin:$alertmanager_path/bin:$kubectl_path/bin:$helm_path/bin:$PATH"
export PYTHONPATH="$pyyaml_path/lib/python$python_version/site-packages${PYTHONPATH:+:$PYTHONPATH}"

test_script="${1:-$root/utils/test-observability-prep.py}"
if (( $# > 0 )); then
  shift
fi
exec "$python_path/bin/python3" "$test_script" "$@"
