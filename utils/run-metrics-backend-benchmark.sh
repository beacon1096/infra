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

prometheus_path="$(realise_bin observability-prometheus prometheus)"
promtool_path="$(realise_bin observability-promtool promtool)"
alertmanager_path="$(realise_bin observability-alertmanager alertmanager)"
victoriametrics_path="$(realise_bin observability-victoriametrics victoria-metrics)"
vmagent_path="$(realise_bin observability-vmagent vmagent)"
python_path="$(realise_bin observability-python python3)"
pyyaml_path="$(realise_paths observability-pyyaml)"

python_version="$($python_path/bin/python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
export PATH="$prometheus_path/bin:$promtool_path/bin:$alertmanager_path/bin:$victoriametrics_path/bin:$vmagent_path/bin:$PATH"
export PYTHONPATH="$pyyaml_path/lib/python$python_version/site-packages${PYTHONPATH:+:$PYTHONPATH}"
export PYTHONUNBUFFERED=1

exec timeout --signal=TERM --kill-after=30s 3600 \
  "$python_path/bin/python3" "$root/utils/metrics-backend-benchmark/run.py" "$@"
