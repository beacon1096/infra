#!/usr/bin/env bash
set -euo pipefail

run_id="${RUN_ID:-}"
phase="${PHASE:-storage}"
longhorn_namespace="${LONGHORN_NAMESPACE:-storage}"
restore_namespace="openstatus-restore-${run_id}"
restore_label="openstatus.beaco.works/restore-run"

usage() {
  cat >&2 <<'EOF'
Validate an applied OpenStatus restore drill without changing it.

Usage:
  RUN_ID=20261015a PHASE=storage bash utils/check-openstatus-restore-drill.sh

  TINYBIRD_RESTORE_TOKEN=... RUN_ID=20261015a PHASE=data \
    bash utils/check-openstatus-restore-drill.sh

PHASE=storage validates labels, restored Longhorn volumes, PVC bindings, and
the read-only filesystem inventory. PHASE=data additionally queries the
isolated libSQL and Tinybird instances and verifies the workflows image can
read its restored tree. Data deployments must have been explicitly scaled up
after the storage phase passed. The token is never printed.
EOF
}

if [[ "$run_id" == "-h" || "$run_id" == "--help" ]]; then
  usage
  exit 0
fi
[[ "$run_id" =~ ^[a-z0-9]([a-z0-9-]{0,22}[a-z0-9])?$ ]] || {
  echo "restore check: RUN_ID must be 1-24 lowercase DNS-label characters" >&2
  exit 2
}
[[ "$phase" == "storage" || "$phase" == "data" ]] || {
  echo "restore check: PHASE must be storage or data" >&2
  exit 2
}
for command in kubectl jq curl; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "restore check: $command is required" >&2
    exit 2
  }
done

namespace_json="$(kubectl get namespace "$restore_namespace" -o json)"
jq -e --arg key "$restore_label" --arg value "$run_id" \
  '.metadata.labels[$key] == $value' <<<"$namespace_json" >/dev/null || {
  echo "restore check: Namespace/$restore_namespace does not carry the exact run label" >&2
  exit 1
}

volume_json="$(kubectl -n "$longhorn_namespace" get volumes.longhorn.io \
  -l "$restore_label=$run_id" -o json)"
jq -e --arg key "$restore_label" --arg value "$run_id" '
  (.items | length) == 3 and
  all(.items[];
    .metadata.labels[$key] == $value and
    .spec.numberOfReplicas == 1 and
    (.spec.fromBackup | length > 0) and
    .status.restoreRequired == false and
    .status.robustness == "healthy" and
    (.status.state == "detached" or .status.state == "attached"))
' <<<"$volume_json" >/dev/null || {
  echo "restore check: expected exactly three healthy, completed, single-replica restore volumes" >&2
  jq -r '.items[] | [
    .metadata.name,
    (.status.state // "-"),
    (.status.robustness // "-"),
    (.status.restoreRequired | tostring),
    (.status.restoreStatus.progress // 0 | tostring)
  ] | @tsv' <<<"$volume_json" >&2
  exit 1
}

pvc_json="$(kubectl -n "$restore_namespace" get pvc \
  -l "$restore_label=$run_id" -o json)"
jq -e --arg key "$restore_label" --arg value "$run_id" '
  (.items | length) == 3 and
  all(.items[];
    .metadata.labels[$key] == $value and
    .status.phase == "Bound" and
    (.spec.volumeName | startswith("osr-")))
' <<<"$pvc_json" >/dev/null || {
  echo "restore check: expected exactly three Bound, run-labeled restore PVCs" >&2
  exit 1
}

job_json="$(kubectl -n "$restore_namespace" get job restore-inventory -o json)"
jq -e '.status.succeeded == 1 and ((.status.failed // 0) == 0)' \
  <<<"$job_json" >/dev/null || {
  echo "restore check: Job/restore-inventory has not succeeded cleanly" >&2
  exit 1
}
inventory_log="$(kubectl -n "$restore_namespace" logs job/restore-inventory)"
grep -q '^RESTORE_INVENTORY_OK$' <<<"$inventory_log" || {
  echo "restore check: inventory completion marker is missing" >&2
  exit 1
}
for component in libsql tinybird workflows; do
  grep -Eq "^RESTORE_INVENTORY component=${component} files=[1-9][0-9]* kib=[0-9]+ readable=true$" \
    <<<"$inventory_log" || {
    echo "restore check: $component did not produce a non-empty readable inventory" >&2
    exit 1
  }
done

printf 'COMPONENT\tVOLUME\tSTATE\tROBUSTNESS\tRESTORE_REQUIRED\tPVC\tPVC_PHASE\n'
for component in libsql tinybird workflows; do
  volume="osr-${run_id}-${component}"
  pvc="restore-${component}-data"
  jq -r --arg volume "$volume" --arg component "$component" '
    .items[] | select(.metadata.name == $volume) |
    [$component, .metadata.name, .status.state, .status.robustness,
      (.status.restoreRequired | tostring)] | @tsv
  ' <<<"$volume_json" | while IFS= read -r line; do
    pvc_phase="$(jq -r --arg pvc "$pvc" '.items[] | select(.metadata.name == $pvc) | .status.phase' <<<"$pvc_json")"
    printf '%s\t%s\t%s\n' "$line" "$pvc" "$pvc_phase"
  done
done
printf '%s\n' "$inventory_log"

if [[ "$phase" == "storage" ]]; then
  echo "restore check: storage phase passed; no data service was queried"
  exit 0
fi

[[ -n "${TINYBIRD_RESTORE_TOKEN:-}" ]] || {
  echo "restore check: TINYBIRD_RESTORE_TOKEN is required for PHASE=data" >&2
  exit 2
}

for deployment in restore-libsql restore-tinybird restore-workflows-reader; do
  deployment_json="$(kubectl -n "$restore_namespace" get deployment "$deployment" -o json)"
  jq -e '
    .spec.replicas == 1 and
    .status.availableReplicas == 1 and
    (.spec.template.spec.containers[0].image | contains("@sha256:"))
  ' <<<"$deployment_json" >/dev/null || {
    echo "restore check: Deployment/$deployment must have one available digest-pinned replica" >&2
    exit 1
  }
done

workflows_log="$(kubectl -n "$restore_namespace" logs deployment/restore-workflows-reader)"
grep -q '^RESTORE_WORKFLOWS_READABLE$' <<<"$workflows_log" || {
  echo "restore check: workflows image did not confirm restored tree readability" >&2
  exit 1
}

check_tmp_dir="$(mktemp -d)"
umask 077
printf 'Authorization: Bearer %s\n' "$TINYBIRD_RESTORE_TOKEN" \
  >"$check_tmp_dir/tinybird-auth-header"
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
  rm -rf -- "$check_tmp_dir"
}
trap cleanup_port_forwards EXIT

kubectl -n "$restore_namespace" port-forward service/restore-libsql 18081:8080 \
  >"$check_tmp_dir/libsql-port-forward.log" 2>&1 &
libsql_pid=$!
kubectl -n "$restore_namespace" port-forward service/restore-tinybird 17181:7181 \
  >"$check_tmp_dir/tinybird-port-forward.log" 2>&1 &
tinybird_pid=$!

for attempt in 1 2 3 4 5 6 7 8 9 10; do
  if curl -fsS http://127.0.0.1:18081/health >/dev/null 2>&1 &&
    curl -fsS http://127.0.0.1:17181/ >/dev/null 2>&1; then
    break
  fi
  if [[ "$attempt" == 10 ]]; then
    echo "restore check: isolated service port-forwards did not become ready" >&2
    sed -n '1,80p' "$check_tmp_dir/libsql-port-forward.log" >&2
    sed -n '1,80p' "$check_tmp_dir/tinybird-port-forward.log" >&2
    exit 1
  fi
  sleep 1
done

libsql_response="$(curl -fsS http://127.0.0.1:18081/v2/pipeline \
  -H 'content-type: application/json' \
  --data '{"requests":[{"type":"execute","stmt":{"sql":"SELECT (SELECT count(*) FROM workspace) AS workspaces, (SELECT count(*) FROM monitor WHERE deleted_at IS NULL) AS monitors, (SELECT count(*) FROM private_location) AS private_locations, (SELECT count(*) FROM private_location_to_monitor WHERE deleted_at IS NULL) AS assignments"}},{"type":"close"}]}')"
jq -e '
  .results[0].type == "ok" and
  .results[0].response.result.rows_written == 0 and
  (.results[0].response.result.rows[0] | length) == 4 and
  all(.results[0].response.result.rows[0][]; (.value | tonumber) > 0)
' <<<"$libsql_response" >/dev/null || {
  echo "restore check: libSQL read did not find workspace, monitor, private-location, and assignment rows" >&2
  exit 1
}

tinybird_sql='SELECT count() AS result_count, uniqExact(timestamp) AS distinct_intervals, min(timestamp) AS first_timestamp, max(timestamp) AS last_timestamp, uniqExact(monitorId) AS monitors, uniqExact(region) AS regions FROM ping_response__v8'
tinybird_response="$(curl -fsS -G http://127.0.0.1:17181/v0/sql \
  -H "@$check_tmp_dir/tinybird-auth-header" \
  --data-urlencode "q=$tinybird_sql")"
jq -e '
  (.data | length) == 1 and
  (.data[0].result_count | tonumber) > 0 and
  (.data[0].distinct_intervals | tonumber) > 0 and
  (.data[0].monitors | tonumber) > 0 and
  (.data[0].regions | tonumber) > 0
' <<<"$tinybird_response" >/dev/null || {
  echo "restore check: Tinybird read did not find stored OpenStatus response rows" >&2
  exit 1
}

printf 'LIBSQL\tworkspaces=%s\tmonitors=%s\tprivate_locations=%s\tassignments=%s\trows_written=0\n' \
  "$(jq -r '.results[0].response.result.rows[0][0].value' <<<"$libsql_response")" \
  "$(jq -r '.results[0].response.result.rows[0][1].value' <<<"$libsql_response")" \
  "$(jq -r '.results[0].response.result.rows[0][2].value' <<<"$libsql_response")" \
  "$(jq -r '.results[0].response.result.rows[0][3].value' <<<"$libsql_response")"
jq -r '.data[0] | ["TINYBIRD", "rows=" + (.result_count | tostring),
  "intervals=" + (.distinct_intervals | tostring),
  "first=" + (.first_timestamp | tostring),
  "last=" + (.last_timestamp | tostring),
  "monitors=" + (.monitors | tostring),
  "regions=" + (.regions | tostring)] | @tsv' <<<"$tinybird_response"
echo "restore check: data phase passed; libSQL and Tinybird were queried read-only"
