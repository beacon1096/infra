#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd -- "$script_dir/.." && pwd)"
fixture_dir="$script_dir/fixtures/openstatus-tinybird"
backup_fixture_dir="$script_dir/fixtures/openstatus-backup"

[[ "$(bash "$script_dir/classify-openstatus-tinybird-query.sh" 200 "$fixture_dir/initialized-empty.json")" == "initialized-empty" ]]
[[ "$(bash "$script_dir/classify-openstatus-tinybird-query.sh" 200 "$fixture_dir/ingested.json")" == "ingested" ]]

set +e
state="$(bash "$script_dir/classify-openstatus-tinybird-query.sh" 400 "$fixture_dir/uninitialized.json")"
rc=$?
set -e
[[ "$state" == "uninitialized" && "$rc" == "4" ]]

set +e
state="$(bash "$script_dir/classify-openstatus-tinybird-query.sh" 403 "$fixture_dir/authentication-failed.json")"
rc=$?
set -e
[[ "$state" == "authentication-failed" && "$rc" == "3" ]]

set +e
state="$(bash "$script_dir/classify-openstatus-tinybird-query.sh" 503 "$fixture_dir/query-failed.json")"
rc=$?
set -e
[[ "$state" == "query-failed" && "$rc" == "1" ]]

datasource="$repo_dir/wanxiang/kubernetes/apps/monitoring/openstatus/bootstrap/tinybird/ping_response__v8.datasource"
[[ "$(sha256sum "$datasource" | awk '{print $1}')" == "ebee697a5b25d3808d2e931d3b0ef77ef2d666e273931099ecabffcf96e96207" ]]

tmp_dir="$(mktemp -d)"
trap 'rm -rf -- "$tmp_dir"' EXIT
RUN_ID=fixture BASELINE_FILE="$backup_fixture_dir/uninitialized-baseline.json" BASELINE_PURPOSE=pre-init \
  bash "$script_dir/render-openstatus-baseline-backup.sh" >"$tmp_dir/backup.yaml"

real_kubectl="$(command -v kubectl)"
cat >"$tmp_dir/kubectl" <<'EOF'
#!/bin/bash
set -euo pipefail

if [[ "${1:-}" == "create" ]]; then
  exec "$REAL_KUBECTL" "$@"
fi
if [[ "$*" == "-n monitoring get pvc "*" -o json" ]]; then
  pvc="${5}"
  suffix="${pvc#openstatus-}"
  suffix="${suffix%-data}"
  printf '{"metadata":{"name":"%s"},"spec":{"volumeName":"pv-%s"},"status":{"phase":"Bound"}}\n' "$pvc" "$suffix"
  exit 0
fi
if [[ "$*" == "get pv "*" -o json" ]]; then
  pv="${3}"
  suffix="${pv#pv-}"
  pvc="openstatus-${suffix}-data"
  volume="vol-$suffix"
  [[ "${BAD_BINDING:-0}" == "1" && "$suffix" == "tinybird" ]] && volume="vol-wrong"
  printf '{"metadata":{"name":"%s"},"spec":{"claimRef":{"namespace":"monitoring","name":"%s"},"csi":{"driver":"driver.longhorn.io","volumeHandle":"%s"}},"status":{"phase":"Bound"}}\n' "$pv" "$pvc" "$volume"
  exit 0
fi
if [[ "$*" == "-n storage get volumes.longhorn.io vol-"*" -o json" ]]; then
  volume="${5}"
  suffix="${volume#vol-}"
  pvc="openstatus-${suffix}-data"
  pv="pv-$suffix"
  labels='{"recurring-job-group.longhorn.io/default":"enabled"}'
  if [[ "${STALE_OSB_LABEL:-0}" == "1" && "$suffix" == "libsql" ]]; then
    labels='{"recurring-job-group.longhorn.io/default":"enabled","recurring-job.longhorn.io/osb-old":"enabled"}'
  fi
  printf '{"metadata":{"name":"%s","labels":%s},"status":{"robustness":"healthy","state":"attached","kubernetesStatus":{"namespace":"monitoring","pvcName":"%s","pvName":"%s"}}}\n' "$volume" "$labels" "$pvc" "$pv"
  exit 0
fi
if [[ "$*" == "-n storage get volumes.longhorn.io -o json" ]]; then
  extra=''
  tinybird_labels='{}'
  if [[ "${PARTIAL_LABEL:-0}" == "1" ]]; then
    tinybird_labels='{"recurring-job.longhorn.io/osb-fixture":"enabled"}'
  fi
  if [[ "${EXTRA_LABEL:-0}" == "1" ]]; then
    extra=',{"metadata":{"name":"vol-extra","labels":{"recurring-job.longhorn.io/osb-fixture":"enabled"}}}'
  fi
  printf '{"items":[{"metadata":{"name":"vol-libsql","labels":{}}},{"metadata":{"name":"vol-tinybird","labels":%s}},{"metadata":{"name":"vol-workflows","labels":{}}}%s]}\n' "$tinybird_labels" "$extra"
  exit 0
fi
if [[ "$*" == "-n storage get recurringjobs.longhorn.io osb-fixture" || "$*" == "-n storage get job osb-fixture" ]]; then
  exit 1
fi
if [[ "$*" == "-n storage get jobs -o json" ]]; then
  case "${DAILY_JOB_STATE:-none}" in
    active)
      printf '%s\n' '{"items":[{"metadata":{"name":"daily-backup-active","ownerReferences":[{"kind":"CronJob","name":"daily-backup"}]},"spec":{"backoffLimit":3},"status":{"active":1,"startTime":"2026-10-15T18:00:00Z","conditions":[]}}]}'
      ;;
    queued)
      printf '%s\n' '{"items":[{"metadata":{"name":"daily-backup-queued","ownerReferences":[{"kind":"CronJob","name":"daily-backup"}]},"spec":{"backoffLimit":3},"status":{"conditions":[]}}]}'
      ;;
    retrying)
      printf '%s\n' '{"items":[{"metadata":{"name":"daily-backup-retrying","ownerReferences":[{"kind":"CronJob","name":"daily-backup"}]},"spec":{"backoffLimit":3},"status":{"active":0,"failed":1,"startTime":"2026-10-15T18:00:00Z","conditions":[]}}]}'
      ;;
    complete)
      printf '%s\n' '{"items":[{"metadata":{"name":"daily-backup-complete","ownerReferences":[{"kind":"CronJob","name":"daily-backup"}]},"spec":{"backoffLimit":3},"status":{"active":0,"succeeded":1,"conditions":[{"type":"Complete","status":"True"}]}}]}'
      ;;
    failed)
      printf '%s\n' '{"items":[{"metadata":{"name":"daily-backup-failed","ownerReferences":[{"kind":"CronJob","name":"daily-backup"}]},"spec":{"backoffLimit":3},"status":{"active":0,"failed":4,"conditions":[{"type":"Failed","status":"True"}]}}]}'
      ;;
    none)
      printf '%s\n' '{"items":[]}'
      ;;
    *)
      exit 2
      ;;
  esac
  exit 0
fi
if [[ "$*" == "-n storage get backups.longhorn.io -o json" ]]; then
  if [[ "${ACTIVE_TARGET_BACKUP:-0}" == "1" ]]; then
    printf '%s\n' '{"items":[{"metadata":{"name":"backup-active","labels":{"backup-volume":"vol-tinybird"}},"spec":{"snapshotName":"snapshot-active"},"status":{"state":"InProgress","progress":42}}]}'
  else
    printf '%s\n' '{"items":[]}'
  fi
  exit 0
fi
exit 1
EOF
chmod +x "$tmp_dir/kubectl"

plan="$(OPENSTATUS_KUBECTL_BIN="$tmp_dir/kubectl" REAL_KUBECTL="$real_kubectl" RUN_ID=fixture \
  BACKUP_MANIFEST="$tmp_dir/backup.yaml" \
  bash "$script_dir/check-openstatus-baseline-backup.sh" plan)"
jq -e '.selector.selected_volume_count == 3 and (.bindings | length) == 3' <<<"$plan" >/dev/null
scope_sha256="$(jq -r .scope_sha256 <<<"$plan")"

conflicts="$(OPENSTATUS_KUBECTL_BIN="$tmp_dir/kubectl" REAL_KUBECTL="$real_kubectl" \
  bash "$script_dir/check-openstatus-backup-conflicts.sh")"
jq -e '
  (.target_bindings | length) == 3 and
  (.active_conflicting_jobs | length) == 0 and
  (.active_target_backups | length) == 0 and
  (.stale_direct_labels | length) == 0
' <<<"$conflicts" >/dev/null

for job_state in active queued retrying; do
  if OPENSTATUS_KUBECTL_BIN="$tmp_dir/kubectl" REAL_KUBECTL="$real_kubectl" \
    DAILY_JOB_STATE="$job_state" \
    bash "$script_dir/check-openstatus-backup-conflicts.sh" >/dev/null 2>&1; then
    echo "initialization/backup fixture: $job_state daily backup unexpectedly passed" >&2
    exit 1
  fi
done
for job_state in complete failed; do
  terminal_jobs="$(OPENSTATUS_KUBECTL_BIN="$tmp_dir/kubectl" REAL_KUBECTL="$real_kubectl" \
    DAILY_JOB_STATE="$job_state" \
    bash "$script_dir/check-openstatus-backup-conflicts.sh")"
  jq -e '(.active_conflicting_jobs | length) == 0' <<<"$terminal_jobs" >/dev/null
done
if OPENSTATUS_KUBECTL_BIN="$tmp_dir/kubectl" REAL_KUBECTL="$real_kubectl" ACTIVE_TARGET_BACKUP=1 \
  bash "$script_dir/check-openstatus-backup-conflicts.sh" >/dev/null 2>&1; then
  echo "initialization/backup fixture: active target backup unexpectedly passed" >&2
  exit 1
fi
if OPENSTATUS_KUBECTL_BIN="$tmp_dir/kubectl" REAL_KUBECTL="$real_kubectl" STALE_OSB_LABEL=1 \
  bash "$script_dir/check-openstatus-backup-conflicts.sh" >/dev/null 2>&1; then
  echo "initialization/backup fixture: stale direct label unexpectedly passed" >&2
  exit 1
fi

cleanup_plan="$(OPENSTATUS_KUBECTL_BIN="$tmp_dir/kubectl" REAL_KUBECTL="$real_kubectl" PARTIAL_LABEL=1 \
  RUN_ID=fixture BACKUP_MANIFEST="$tmp_dir/backup.yaml" \
  EXPECTED_SCOPE_SHA256="$scope_sha256" \
  bash "$script_dir/check-openstatus-baseline-backup.sh" cleanup-plan)"
grep -q 'Preserve all Backup, Snapshot, PV, PVC' <<<"$cleanup_plan"

if OPENSTATUS_KUBECTL_BIN="$tmp_dir/kubectl" REAL_KUBECTL="$real_kubectl" EXTRA_LABEL=1 RUN_ID=fixture \
  BACKUP_MANIFEST="$tmp_dir/backup.yaml" \
  bash "$script_dir/check-openstatus-baseline-backup.sh" plan >/dev/null 2>&1; then
  echo "initialization/backup fixture: extra selected volume unexpectedly passed" >&2
  exit 1
fi
if OPENSTATUS_KUBECTL_BIN="$tmp_dir/kubectl" REAL_KUBECTL="$real_kubectl" EXTRA_LABEL=1 RUN_ID=fixture \
  BACKUP_MANIFEST="$tmp_dir/backup.yaml" EXPECTED_SCOPE_SHA256="$scope_sha256" \
  bash "$script_dir/check-openstatus-baseline-backup.sh" cleanup-plan >/dev/null 2>&1; then
  echo "initialization/backup fixture: cleanup accepted an extra selected volume" >&2
  exit 1
fi
if OPENSTATUS_KUBECTL_BIN="$tmp_dir/kubectl" REAL_KUBECTL="$real_kubectl" BAD_BINDING=1 RUN_ID=fixture \
  BACKUP_MANIFEST="$tmp_dir/backup.yaml" \
  bash "$script_dir/check-openstatus-baseline-backup.sh" plan >/dev/null 2>&1; then
  echo "initialization/backup fixture: changed binding unexpectedly passed" >&2
  exit 1
fi

echo "initialization/backup fixtures: states, pinned resource, exact scope, conflict and refusal paths passed"
