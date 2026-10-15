#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
validator="$script_dir/validate-openstatus-acceptance-evidence.sh"
fixtures="$script_dir/fixtures/openstatus-acceptance"

bash "$validator" "$fixtures/normal.json" >/dev/null
for rejected in duplicate-success latest-failure stale stale-heartbeat empty; do
  if bash "$validator" "$fixtures/${rejected}.json" >/dev/null 2>&1; then
    echo "acceptance fixture: expected ${rejected}.json to fail" >&2
    exit 1
  fi
done

echo "acceptance fixtures: normal passed; duplicate/latest-failure/stale-result/stale-heartbeat/empty were rejected"
