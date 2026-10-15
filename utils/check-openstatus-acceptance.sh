#!/usr/bin/env bash
set -euo pipefail

openstatus_namespace="${OPENSTATUS_NAMESPACE:-monitoring}"
observation_since="${OBSERVATION_SINCE:-}"
real_monitor_id="${REAL_MONITOR_ID:-}"
real_region_id="${REAL_REGION_ID:-}"
real_target_url="${REAL_TARGET_URL:-}"
canary_monitor_id="${CANARY_MONITOR_ID:-}"
canary_region_id="${CANARY_REGION_ID:-}"
canary_target_url="${CANARY_TARGET_URL:-}"
failure_at="${FAILURE_AT:-}"
recovery_at="${RECOVERY_AT:-}"
restart_after="${RESTART_AFTER:-}"
status_page_url="${STATUS_PAGE_URL:-}"
status_page_expect="${STATUS_PAGE_EXPECT:-}"
minimum_real_intervals="${MINIMUM_REAL_INTERVALS:-2}"

usage() {
  cat >&2 <<'EOF'
Read-only post-rollout acceptance check for OpenStatus private probes.

Required environment:
  OBSERVATION_SINCE       RFC3339 beginning of the evidence window
  REAL_MONITOR_ID         numeric real-site monitor id
  REAL_REGION_ID          numeric private-location id assigned to it
  REAL_TARGET_URL         exact URL stored in libSQL
  CANARY_MONITOR_ID       numeric dedicated failure-canary monitor id
  CANARY_REGION_ID        numeric private-location id assigned to it
  CANARY_TARGET_URL       exact canary URL stored in libSQL
  FAILURE_AT              RFC3339 time the canary was made to fail
  RECOVERY_AT             RFC3339 time the canary was restored
  RESTART_AFTER           RFC3339 time before the controlled app restart
  STATUS_PAGE_URL         published page to read
  STATUS_PAGE_EXPECT      literal non-secret text identifying the real service
  TINYBIRD_READ_TOKEN     read-capable Tinybird Local token (never printed)

The script does not create monitors, stop a target, restart pods, or mutate
OpenStatus. It verifies those separately approved actions from libSQL,
Tinybird, logs, workloads, and the public status page.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi
for command in kubectl jq curl date grep; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "acceptance: $command is required" >&2
    exit 2
  }
done
for value_name in observation_since real_target_url canary_target_url failure_at recovery_at restart_after status_page_url status_page_expect; do
  [[ -n "${!value_name}" ]] || {
    echo "acceptance: ${value_name^^} is required" >&2
    usage
    exit 2
  }
done
for value_name in real_monitor_id real_region_id canary_monitor_id canary_region_id minimum_real_intervals; do
  [[ "${!value_name}" =~ ^[1-9][0-9]*$ ]] || {
    echo "acceptance: ${value_name^^} must be a positive integer" >&2
    exit 2
  }
done
[[ -n "${TINYBIRD_READ_TOKEN:-}" ]] || {
  echo "acceptance: TINYBIRD_READ_TOKEN is required" >&2
  exit 2
}
[[ "$real_monitor_id" != "$canary_monitor_id" ]] || {
  echo "acceptance: the real-site and failure-canary monitors must be distinct" >&2
  exit 2
}

observation_since_epoch="$(date -u -d "$observation_since" +%s)"
failure_epoch="$(date -u -d "$failure_at" +%s)"
recovery_epoch="$(date -u -d "$recovery_at" +%s)"
restart_epoch="$(date -u -d "$restart_after" +%s)"
(( observation_since_epoch < failure_epoch && failure_epoch < recovery_epoch )) || {
  echo "acceptance: require OBSERVATION_SINCE < FAILURE_AT < RECOVERY_AT" >&2
  exit 2
}
observation_since_ms="$((observation_since_epoch * 1000))"
failure_ms="$((failure_epoch * 1000))"
recovery_ms="$((recovery_epoch * 1000))"

for deployment in openstatus-private-location openstatus-probe-wanxiang; do
  deployment_json="$(kubectl -n "$openstatus_namespace" get deployment "$deployment" -o json)"
  jq -e '
    .spec.replicas == 1 and
    .status.availableReplicas == 1 and
    (.spec.template.spec.containers[0].image | contains("@sha256:"))
  ' <<<"$deployment_json" >/dev/null || {
    echo "acceptance: Deployment/$deployment must have one available digest-pinned replica" >&2
    exit 1
  }
done

server_pods="$(kubectl -n "$openstatus_namespace" get pods \
  -l app.kubernetes.io/name=openstatus-server -o json)"
jq -e --argjson restart "$restart_epoch" '
  any(.items[];
    (.status.phase == "Running") and
    ((.status.startTime | fromdateiso8601) > $restart))
' <<<"$server_pods" >/dev/null || {
  echo "acceptance: no running API-server pod started after RESTART_AFTER" >&2
  exit 1
}

probe_logs="$(kubectl -n "$openstatus_namespace" logs deployment/openstatus-probe-wanxiang \
  --since-time "$observation_since")"
grep -q 'Started monitoring job' <<<"$probe_logs" || {
  echo "acceptance: active probe has no monitoring-job start evidence in the window" >&2
  exit 1
}
receiver_logs="$(kubectl -n "$openstatus_namespace" logs deployment/openstatus-private-location \
  --since-time "$observation_since")"
grep -q 'tinybird.success=true' <<<"$receiver_logs" || {
  echo "acceptance: receiver has no sampled tinybird.success=true ingest evidence" >&2
  exit 1
}

acceptance_tmp_dir="$(mktemp -d)"
umask 077
printf 'Authorization: Bearer %s\n' "$TINYBIRD_READ_TOKEN" \
  >"$acceptance_tmp_dir/tinybird-auth-header"
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
  rm -rf -- "$acceptance_tmp_dir"
}
trap cleanup_port_forwards EXIT

kubectl -n "$openstatus_namespace" port-forward service/openstatus-libsql 18082:8080 \
  >"$acceptance_tmp_dir/libsql-port-forward.log" 2>&1 &
libsql_pid=$!
kubectl -n "$openstatus_namespace" port-forward service/openstatus-tinybird 17182:7181 \
  >"$acceptance_tmp_dir/tinybird-port-forward.log" 2>&1 &
tinybird_pid=$!

for attempt in 1 2 3 4 5 6 7 8 9 10; do
  if curl -fsS http://127.0.0.1:18082/health >/dev/null 2>&1 &&
    curl -fsS http://127.0.0.1:17182/ >/dev/null 2>&1; then
    break
  fi
  if [[ "$attempt" == 10 ]]; then
    echo "acceptance: datastore port-forwards did not become ready" >&2
    exit 1
  fi
  sleep 1
done

libsql_statement="SELECT m.id, m.url, m.active, p.id, p.last_seen_at FROM monitor m JOIN private_location_to_monitor a ON a.monitor_id = m.id AND a.deleted_at IS NULL JOIN private_location p ON p.id = a.private_location_id WHERE m.deleted_at IS NULL AND ((m.id = ${real_monitor_id} AND p.id = ${real_region_id}) OR (m.id = ${canary_monitor_id} AND p.id = ${canary_region_id})) ORDER BY m.id"
libsql_request="$(jq -cn --arg sql "$libsql_statement" '{requests:[{type:"execute",stmt:{sql:$sql}},{type:"close"}]}')"
libsql_response="$(curl -fsS http://127.0.0.1:18082/v2/pipeline \
  -H 'content-type: application/json' --data "$libsql_request")"
jq -e --argjson since "$observation_since_epoch" '
  .results[0].type == "ok" and
  .results[0].response.result.rows_written == 0 and
  (.results[0].response.result.rows | length) == 2 and
  all(.results[0].response.result.rows[];
    .[2].value == "1" and (.[4].value | tonumber) >= $since)
' <<<"$libsql_response" >/dev/null || {
  echo "acceptance: libSQL lacks both active assignments with fresh private-location heartbeats" >&2
  exit 1
}

real_row_url="$(jq -r --arg id "$real_monitor_id" '
  .results[0].response.result.rows[] | select(.[0].value == $id) | .[1].value
' <<<"$libsql_response")"
canary_row_url="$(jq -r --arg id "$canary_monitor_id" '
  .results[0].response.result.rows[] | select(.[0].value == $id) | .[1].value
' <<<"$libsql_response")"
[[ "$real_row_url" == "$real_target_url" && "$canary_row_url" == "$canary_target_url" ]] || {
  echo "acceptance: libSQL monitor URLs do not match the declared real/canary targets" >&2
  exit 1
}

tinybird_sql="SELECT monitorId, region, count() AS samples, uniqExact(cronTimestamp) AS intervals, countIf(requestStatus = 'success') AS successes, countIf(requestStatus = 'error') AS failures, countIf(requestStatus = 'success' AND cronTimestamp < ${failure_ms}) AS pre_failure_successes, countIf(requestStatus = 'error' AND cronTimestamp >= ${failure_ms} AND cronTimestamp < ${recovery_ms}) AS controlled_failures, countIf(requestStatus = 'success' AND cronTimestamp >= ${recovery_ms}) AS post_recovery_successes, min(cronTimestamp) AS first_interval, max(cronTimestamp) AS last_interval FROM ping_response__v8 WHERE cronTimestamp >= ${observation_since_ms} AND ((monitorId = '${real_monitor_id}' AND region = '${real_region_id}') OR (monitorId = '${canary_monitor_id}' AND region = '${canary_region_id}')) GROUP BY monitorId, region ORDER BY monitorId"
tinybird_response="$(curl -fsS -G http://127.0.0.1:17182/v0/sql \
  -H "@$acceptance_tmp_dir/tinybird-auth-header" \
  --data-urlencode "q=$tinybird_sql")"

jq -e \
  --arg real "$real_monitor_id" \
  --arg real_region "$real_region_id" \
  --argjson minimum "$minimum_real_intervals" '
  any(.data[];
    .monitorId == $real and .region == $real_region and
    (.intervals | tonumber) >= $minimum and
    (.successes | tonumber) >= $minimum)
' <<<"$tinybird_response" >/dev/null || {
  echo "acceptance: real target lacks stored successes across the required intervals" >&2
  exit 1
}
jq -e \
  --arg canary "$canary_monitor_id" \
  --arg canary_region "$canary_region_id" '
  any(.data[];
    .monitorId == $canary and .region == $canary_region and
    (.pre_failure_successes | tonumber) > 0 and
    (.controlled_failures | tonumber) > 0 and
    (.post_recovery_successes | tonumber) > 0)
' <<<"$tinybird_response" >/dev/null || {
  echo "acceptance: canary lacks the required success -> failure -> later success sequence" >&2
  exit 1
}

status_page_body="$(curl -fsS --max-time 20 "$status_page_url")"
grep -Fq -- "$status_page_expect" <<<"$status_page_body" || {
  echo "acceptance: published status page does not contain STATUS_PAGE_EXPECT" >&2
  exit 1
}

printf 'MONITOR\tREGION\tSAMPLES\tINTERVALS\tSUCCESS\tFAILURE\tPRE_SUCCESS\tCONTROLLED_FAILURE\tPOST_SUCCESS\tFIRST_MS\tLAST_MS\n'
jq -r '.data[] | [.monitorId, .region, .samples, .intervals, .successes,
  .failures, .pre_failure_successes, .controlled_failures,
  .post_recovery_successes, .first_interval, .last_interval] | @tsv' \
  <<<"$tinybird_response"
echo "acceptance: continuous ingest, controlled failure/recovery, restart persistence, and status-page checks passed"
