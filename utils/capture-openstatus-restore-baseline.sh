#!/usr/bin/env bash
set -euo pipefail

openstatus_namespace="${OPENSTATUS_NAMESPACE:-monitoring}"
upstream_revision="${OPENSTATUS_UPSTREAM_REVISION:-ef7691ad18971c14b9bd1a306b4bd0cf20b6e411}"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat >&2 <<'EOF'
Capture a read-only pre-backup OpenStatus data baseline as JSON on stdout.

Usage:
  TINYBIRD_READ_TOKEN=... bash utils/capture-openstatus-restore-baseline.sh \
    > openstatus-baseline.json

The script fails after writing evidence when ping_response__v8 is not
initialized. Capture while production writers are quiescent, then require the
selected backup snapshot timestamps to be at or after captured_at.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi
[[ -n "${TINYBIRD_READ_TOKEN:-}" ]] || {
  echo "baseline capture: TINYBIRD_READ_TOKEN is required" >&2
  exit 2
}
for command in kubectl jq curl date; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "baseline capture: $command is required" >&2
    exit 2
  }
done

capture_tmp_dir="$(mktemp -d)"
umask 077
printf 'Authorization: Bearer %s\n' "$TINYBIRD_READ_TOKEN" \
  >"$capture_tmp_dir/tinybird-auth-header"
libsql_pid=""
tinybird_pid=""
cleanup_port_forwards() {
  if [[ -n "$libsql_pid" ]]; then
    kill "$libsql_pid" 2>/dev/null || true
    wait "$libsql_pid" 2>/dev/null || true
  fi
  if [[ -n "$tinybird_pid" ]]; then
    kill "$tinybird_pid" 2>/dev/null || true
    wait "$tinybird_pid" 2>/dev/null || true
  fi
  rm -rf -- "$capture_tmp_dir"
}
trap cleanup_port_forwards EXIT

kubectl -n "$openstatus_namespace" port-forward service/openstatus-libsql 18083:8080 \
  >"$capture_tmp_dir/libsql-port-forward.log" 2>&1 &
libsql_pid=$!
kubectl -n "$openstatus_namespace" port-forward service/openstatus-tinybird 17183:7181 \
  >"$capture_tmp_dir/tinybird-port-forward.log" 2>&1 &
tinybird_pid=$!

for attempt in 1 2 3 4 5 6 7 8 9 10; do
  if curl -fsS http://127.0.0.1:18083/health >/dev/null 2>&1 &&
    curl -fsS http://127.0.0.1:17183/ >/dev/null 2>&1; then
    break
  fi
  if [[ "$attempt" == 10 ]]; then
    echo "baseline capture: datastore port-forwards did not become ready" >&2
    exit 1
  fi
  sleep 1
done

libsql_response="$(curl -fsS http://127.0.0.1:18083/v2/pipeline \
  -H 'content-type: application/json' \
  --data '{"requests":[{"type":"execute","stmt":{"sql":"SELECT (SELECT count(*) FROM workspace) AS workspaces, (SELECT count(*) FROM monitor WHERE deleted_at IS NULL) AS monitors, (SELECT count(*) FROM private_location) AS private_locations, (SELECT count(*) FROM private_location_to_monitor WHERE deleted_at IS NULL) AS assignments"}},{"type":"close"}]}')"
jq -e '
  .results[0].type == "ok" and
  .results[0].response.result.rows_written == 0 and
  (.results[0].response.result.rows[0] | length) == 4
' <<<"$libsql_response" >/dev/null || {
  echo "baseline capture: libSQL read failed" >&2
  exit 1
}

tinybird_sql='SELECT count() AS result_count, uniqExact(cronTimestamp) AS distinct_intervals, uniqExact(monitorId) AS monitors, uniqExact(region) AS regions FROM ping_response__v8'
tinybird_http_code="$(curl -sS -G http://127.0.0.1:17183/v0/sql \
  -H "@$capture_tmp_dir/tinybird-auth-header" \
  --data-urlencode "q=$tinybird_sql" \
  -o "$capture_tmp_dir/tinybird-response.json" -w '%{http_code}')"
tinybird_state="uninitialized"
tinybird_rows=0
tinybird_intervals=0
tinybird_monitors=0
tinybird_regions=0
set +e
tinybird_state="$(bash "$script_dir/classify-openstatus-tinybird-query.sh" \
  "$tinybird_http_code" "$capture_tmp_dir/tinybird-response.json")"
tinybird_state_rc=$?
set -e
if [[ "$tinybird_state_rc" == "0" ]]; then
  tinybird_rows="$(jq -r '.data[0].result_count | tonumber' "$capture_tmp_dir/tinybird-response.json")"
  tinybird_intervals="$(jq -r '.data[0].distinct_intervals | tonumber' "$capture_tmp_dir/tinybird-response.json")"
  tinybird_monitors="$(jq -r '.data[0].monitors | tonumber' "$capture_tmp_dir/tinybird-response.json")"
  tinybird_regions="$(jq -r '.data[0].regions | tonumber' "$capture_tmp_dir/tinybird-response.json")"
fi

jq -n \
  --arg captured_at "$(date -u +%FT%TZ)" \
  --arg revision "$upstream_revision" \
  --argjson workspaces "$(jq -r '.results[0].response.result.rows[0][0].value | tonumber' <<<"$libsql_response")" \
  --argjson monitors "$(jq -r '.results[0].response.result.rows[0][1].value | tonumber' <<<"$libsql_response")" \
  --argjson private_locations "$(jq -r '.results[0].response.result.rows[0][2].value | tonumber' <<<"$libsql_response")" \
  --argjson assignments "$(jq -r '.results[0].response.result.rows[0][3].value | tonumber' <<<"$libsql_response")" \
  --arg tinybird_state "$tinybird_state" \
  --argjson tinybird_rows "$tinybird_rows" \
  --argjson tinybird_intervals "$tinybird_intervals" \
  --argjson tinybird_monitors "$tinybird_monitors" \
  --argjson tinybird_regions "$tinybird_regions" '
  {
    schema_version: 1,
    captured_at: $captured_at,
    upstream_revision: $revision,
    libsql: {
      workspaces: $workspaces,
      monitors: $monitors,
      private_locations: $private_locations,
      assignments: $assignments
    },
    tinybird: {
      state: $tinybird_state,
      rows: $tinybird_rows,
      intervals: $tinybird_intervals,
      monitors: $tinybird_monitors,
      regions: $tinybird_regions
    }
  }
'

case "$tinybird_state" in
  initialized-empty | ingested) ;;
  uninitialized)
    echo "baseline capture: ping_response__v8 is uninitialized" >&2
    exit 4
    ;;
  authentication-failed)
    echo "baseline capture: Tinybird read authentication failed" >&2
    exit 3
    ;;
  *)
    echo "baseline capture: Tinybird query failed for a reason other than an absent datasource" >&2
    exit 1
    ;;
esac
