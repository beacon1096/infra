#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
fixtures="$script_dir/fixtures/openstatus-restore"
validator="$script_dir/validate-openstatus-restore-baseline.sh"

bash "$validator" "$fixtures/baseline-empty.json" "$fixtures/baseline-empty.json" >/dev/null
bash "$validator" "$fixtures/baseline-ingested.json" "$fixtures/baseline-ingested.json" >/dev/null
for pair in \
  "baseline-empty.json actual-mismatch.json" \
  "baseline-uninitialized.json baseline-uninitialized.json"; do
  read -r expected actual <<<"$pair"
  if bash "$validator" "$fixtures/$expected" "$fixtures/$actual" >/dev/null 2>&1; then
    echo "restore baseline fixture: expected $expected vs $actual to fail" >&2
    exit 1
  fi
done

echo "restore baseline fixtures: initialized-empty and ingested passed; mismatch and uninitialized were rejected"
