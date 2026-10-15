#!/usr/bin/env bash
set -euo pipefail

openstatus_namespace="${OPENSTATUS_NAMESPACE:-monitoring}"
longhorn_namespace="${LONGHORN_NAMESPACE:-storage}"
max_age_hours="${MAX_BACKUP_AGE_HOURS:-26}"
required_pvcs=(
  openstatus-libsql-data
  openstatus-tinybird-data
  openstatus-workflows-data
)

for command in kubectl jq date; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "openstatus backup check: $command is required" >&2
    exit 2
  }
done

[[ "$max_age_hours" =~ ^[1-9][0-9]*$ ]] || {
  echo "openstatus backup check: MAX_BACKUP_AGE_HOURS must be a positive integer" >&2
  exit 2
}

target_json="$(kubectl -n "$longhorn_namespace" get backuptargets.longhorn.io default -o json)"
job_json="$(kubectl -n "$longhorn_namespace" get recurringjobs.longhorn.io daily-backup -o json)"
backups_json="$(kubectl -n "$longhorn_namespace" get backups.longhorn.io -o json)"

jq -e '.status.available == true' <<<"$target_json" >/dev/null || {
  echo "openstatus backup check: BackupTarget/default is unavailable" >&2
  exit 1
}
jq -e '.spec.task == "backup" and (.spec.groups | index("default") != null)' \
  <<<"$job_json" >/dev/null || {
  echo "openstatus backup check: RecurringJob/daily-backup does not select the default backup group" >&2
  exit 1
}

now_epoch="$(date -u +%s)"
max_age_seconds="$((max_age_hours * 3600))"
failures=0

printf 'PVC\tVOLUME\tGROUP\tBACKUP\tSTATE\tCREATED_AT\tAGE_HOURS\tRESULT\n'
for pvc in "${required_pvcs[@]}"; do
  pvc_json="$(kubectl -n "$openstatus_namespace" get pvc "$pvc" -o json)"
  phase="$(jq -r '.status.phase // ""' <<<"$pvc_json")"
  pv="$(jq -r '.spec.volumeName // ""' <<<"$pvc_json")"
  handle=""
  group=""
  backup_name=""
  backup_state=""
  backup_time=""
  backup_error=""
  age_hours="-"
  result="ok"

  if [[ "$phase" != "Bound" || -z "$pv" ]]; then
    result="pvc-not-bound"
  else
    handle="$(kubectl get pv "$pv" -o jsonpath='{.spec.csi.volumeHandle}')"
    if [[ -z "$handle" ]]; then
      result="missing-volume-handle"
    else
      volume_json="$(kubectl -n "$longhorn_namespace" get volumes.longhorn.io "$handle" -o json)"
      group="$(jq -r '.metadata.labels["recurring-job-group.longhorn.io/default"] // ""' <<<"$volume_json")"
      if [[ "$group" != "enabled" ]]; then
        result="daily-backup-not-bound"
      fi

      IFS=$'\t' read -r backup_name backup_state backup_time backup_error < <(
        jq -r --arg volume "$handle" '
          [.items[] | select((.status.volumeName // .spec.volumeName // "") == $volume)]
          | sort_by(.status.snapshotCreatedAt // "")
          | last
          | if . == null then ["", "", "", ""]
            else [
              .metadata.name,
              (.status.state // ""),
              (.status.snapshotCreatedAt // ""),
              (.status.error // "")
            ] end
          | @tsv
        ' <<<"$backups_json"
      )

      if [[ -z "$backup_name" || -z "$backup_time" ]]; then
        result="no-backup"
      elif [[ "$backup_state" != "Completed" || -n "$backup_error" ]]; then
        result="latest-backup-not-completed"
      else
        backup_epoch="$(date -u -d "$backup_time" +%s)"
        age_seconds="$((now_epoch - backup_epoch))"
        age_hours="$((age_seconds / 3600))"
        if (( age_seconds < 0 || age_seconds > max_age_seconds )); then
          result="stale-backup"
        fi
      fi
    fi
  fi

  if [[ "$result" != "ok" ]]; then
    failures=$((failures + 1))
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$pvc" "${handle:--}" "${group:--}" "${backup_name:--}" \
    "${backup_state:--}" "${backup_time:--}" "$age_hours" "$result"
done

if (( failures > 0 )); then
  echo "openstatus backup check: $failures volume(s) failed; Job succeeded and BackupTarget available are not backup-success evidence" >&2
  exit 1
fi

echo "openstatus backup check: all required volumes have a completed backup no older than ${max_age_hours}h"
