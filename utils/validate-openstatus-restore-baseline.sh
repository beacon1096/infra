#!/usr/bin/env bash
set -euo pipefail

expected_file="${1:-}"
actual_file="${2:-}"

if [[ -z "$expected_file" || -z "$actual_file" || "$expected_file" == "-h" || "$expected_file" == "--help" ]]; then
  echo "usage: validate-openstatus-restore-baseline.sh EXPECTED.json ACTUAL.json" >&2
  exit 2
fi
for file in "$expected_file" "$actual_file"; do
  [[ -r "$file" ]] || {
    echo "restore baseline: cannot read $file" >&2
    exit 2
  }
done
command -v jq >/dev/null 2>&1 || {
  echo "restore baseline: jq is required" >&2
  exit 2
}

validate_shape() {
  local file="$1"
  jq -e '
    .schema_version == 1 and
    (.libsql | [.workspaces, .monitors, .private_locations, .assignments] |
      all(.[]; type == "number" and . >= 0)) and
    (.tinybird.state == "initialized-empty" or .tinybird.state == "ingested") and
    (.tinybird | [.rows, .intervals, .monitors, .regions] |
      all(.[]; type == "number" and . >= 0)) and
    (if .tinybird.state == "initialized-empty" then
      ([.tinybird.rows, .tinybird.intervals, .tinybird.monitors, .tinybird.regions] | all(.[]; . == 0))
    else
      ([.tinybird.rows, .tinybird.intervals, .tinybird.monitors, .tinybird.regions] | all(.[]; . > 0))
    end)
  ' "$file" >/dev/null
}

validate_shape "$expected_file" || {
  echo "restore baseline: expected baseline is uninitialized or internally inconsistent" >&2
  exit 1
}
validate_shape "$actual_file" || {
  echo "restore baseline: restored data is uninitialized or internally inconsistent" >&2
  exit 1
}

jq -e -n --slurpfile expected "$expected_file" --slurpfile actual "$actual_file" '
  ($expected[0].libsql == $actual[0].libsql) and
  ($expected[0].tinybird == $actual[0].tinybird)
' >/dev/null || {
  echo "restore baseline: restored counts/state do not match the recorded pre-backup baseline" >&2
  exit 1
}

echo "restore baseline: exact libSQL and Tinybird state/counts match"
