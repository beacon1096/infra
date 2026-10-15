#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

realise_paths() {
  nix build --no-link --print-out-paths "$root#$1"
}

realise_bin() {
  local attr="$1"
  local binary="$2"
  local path

  while IFS= read -r path; do
    if [[ -x "$path/bin/$binary" ]]; then
      printf '%s\n' "$path"
      return 0
    fi
  done < <(realise_paths "$attr")

  printf 'error: %s did not provide bin/%s\n' "$attr" "$binary" >&2
  return 1
}

promtool_path="$(realise_bin observability-promtool promtool)"
alertmanager_path="$(realise_bin observability-alertmanager alertmanager)"
kubectl_path="$(realise_bin observability-kubectl kubectl)"
helm_path="$(realise_bin observability-helm helm)"
python_path="$(realise_bin observability-python python3)"
pyyaml_path="$(realise_paths observability-pyyaml)"

python_version="$($python_path/bin/python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
export PATH="$promtool_path/bin:$alertmanager_path/bin:$kubectl_path/bin:$helm_path/bin:$PATH"
export PYTHONPATH="$pyyaml_path/lib/python$python_version/site-packages${PYTHONPATH:+:$PYTHONPATH}"

test_script="${1:-$root/utils/test-observability-prep.py}"
if (( $# > 0 )); then
  shift
fi
exec "$python_path/bin/python3" "$test_script" "$@"
