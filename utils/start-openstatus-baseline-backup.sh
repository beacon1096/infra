#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
run_id="${RUN_ID:-}"
baseline_purpose="${BASELINE_PURPOSE:-}"
initialize_tinybird="${INITIALIZE_TINYBIRD:-never}"
baseline_file="${BASELINE_FILE:-}"
backup_manifest="${BACKUP_MANIFEST:-}"
scope_file="${BACKUP_SCOPE_FILE:-}"
deadline="${QUIESCE_DEADLINE_EPOCH:-}"
openstatus_namespace="${OPENSTATUS_NAMESPACE:-monitoring}"
longhorn_namespace="${LONGHORN_NAMESPACE:-storage}"
job_name="osb-$run_id"
conflict_check="$script_dir/check-openstatus-backup-conflicts.sh"

usage() {
  cat >&2 <<'EOF'
Run only as the payload of with-openstatus-quiesced.sh. Required environment:
  RUN_ID, BASELINE_PURPOSE, BASELINE_FILE, BACKUP_MANIFEST, BACKUP_SCOPE_FILE,
  REPLICA_STATE_FILE, EXPECTED_REPLICA_STATE_SHA256 and TINYBIRD_READ_TOKEN.

The script captures the data baseline, selects exactly the three OpenStatus
volumes, starts their temporary backup job and waits only for snapshot/backup
registration. Set INITIALIZE_TINYBIRD=execute only for the approved post-init
stage; initialization then runs before baseline capture while writers are
stopped. Upload completion is verified after writers have resumed.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi
[[ "$run_id" =~ ^[a-z0-9]([a-z0-9-]{0,18}[a-z0-9])?$ ]] || {
  echo "OpenStatus baseline backup: invalid RUN_ID" >&2
  exit 2
}
[[ "$baseline_purpose" == "pre-init" || "$baseline_purpose" == "post-init" ]] || {
  echo "OpenStatus baseline backup: BASELINE_PURPOSE must be pre-init or post-init" >&2
  exit 2
}
[[ "$initialize_tinybird" == "never" || "$initialize_tinybird" == "execute" ]] || {
  echo "OpenStatus baseline backup: INITIALIZE_TINYBIRD must be never or execute" >&2
  exit 2
}
if [[ "$initialize_tinybird" == "execute" ]]; then
  [[ "$baseline_purpose" == "post-init" ]] || {
    echo "OpenStatus baseline backup: initialization requires BASELINE_PURPOSE=post-init" >&2
    exit 2
  }
  [[ "${CONFIRM_TINYBIRD_INITIALIZE:-}" == "ping_response__v8@ef7691ad" &&
    -n "${TINYBIRD_CREATE_TOKEN:-}" ]] || {
    echo "OpenStatus baseline backup: approved initialization confirmation and create token are required" >&2
    exit 2
  }
fi
[[ -n "$baseline_file" && -n "$backup_manifest" && -n "$scope_file" ]] || {
  echo "OpenStatus baseline backup: output file paths are required" >&2
  exit 2
}
[[ -n "${TINYBIRD_READ_TOKEN:-}" ]] || {
  echo "OpenStatus baseline backup: TINYBIRD_READ_TOKEN is required" >&2
  exit 2
}
[[ "$deadline" =~ ^[0-9]+$ ]] && (( deadline > $(date -u +%s) )) || {
  echo "OpenStatus baseline backup: active maintenance deadline is required" >&2
  exit 2
}
for output_file in "$baseline_file" "$backup_manifest" "$scope_file"; do
  [[ ! -e "$output_file" ]] || {
    echo "OpenStatus baseline backup: refusing to overwrite $output_file" >&2
    exit 1
  }
done
for command in bash env jq timeout date sha256sum head; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "OpenStatus baseline backup: $command is required" >&2
    exit 2
  }
done
[[ -r "$conflict_check" ]] || {
  echo "OpenStatus baseline backup: conflict checker is missing" >&2
  exit 2
}
kubectl_path="${OPENSTATUS_KUBECTL_BIN:-$(command -v kubectl || true)}"
[[ -n "$kubectl_path" && -r "$kubectl_path" ]] || {
  echo "OpenStatus baseline backup: kubectl is required" >&2
  exit 2
}
kubectl_command=("$kubectl_path")
if [[ "$(head -c 2 -- "$kubectl_path")" == '#!' ]]; then
  kubectl_command=(bash "$kubectl_path")
fi

bounded() {
  local remaining
  remaining=$((deadline - $(date -u +%s)))
  if (( remaining <= 0 )); then
    echo "OpenStatus baseline backup: maintenance deadline expired" >&2
    return 124
  fi
  timeout --foreground --kill-after=5s "${remaining}s" "$@"
}

check_backup_conflicts() {
  bounded env OPENSTATUS_KUBECTL_BIN="$kubectl_path" \
    OPENSTATUS_NAMESPACE="$openstatus_namespace" \
    LONGHORN_NAMESPACE="$longhorn_namespace" \
    bash "$conflict_check" >/dev/null
}

umask 077
check_backup_conflicts
if [[ "$initialize_tinybird" == "execute" ]]; then
  bounded bash "$script_dir/initialize-openstatus-tinybird.sh" --execute
fi
set +e
bounded bash "$script_dir/capture-openstatus-restore-baseline.sh" >"$baseline_file"
baseline_rc=$?
set -e
if [[ "$baseline_purpose" == "pre-init" ]]; then
  [[ "$baseline_rc" == "4" ]] || {
    echo "OpenStatus baseline backup: pre-init capture must classify uninitialized (exit 4), got $baseline_rc" >&2
    exit 1
  }
else
  [[ "$baseline_rc" == "0" ]] || {
    echo "OpenStatus baseline backup: post-init capture must classify initialized data (exit 0), got $baseline_rc" >&2
    exit 1
  }
fi

BASELINE_PURPOSE="$baseline_purpose" RUN_ID="$run_id" BASELINE_FILE="$baseline_file" \
  bounded bash "$script_dir/render-openstatus-baseline-backup.sh" >"$backup_manifest"
RUN_ID="$run_id" BACKUP_MANIFEST="$backup_manifest" \
  bounded bash "$script_dir/check-openstatus-baseline-backup.sh" plan >"$scope_file"
expected_scope_sha256="$(jq -r '.scope_sha256 // ""' "$scope_file")"
[[ "$expected_scope_sha256" =~ ^[0-9a-f]{64}$ ]] || {
  echo "OpenStatus baseline backup: scope plan did not produce a SHA-256" >&2
  exit 1
}

# Recheck immediately before the first storage mutation. The earlier check
# avoids quiescing into a known conflict; this one closes the baseline-capture
# interval without trying to lock or modify the shared backup controller.
check_backup_conflicts
bounded "${kubectl_command[@]}" apply -f "$backup_manifest" >/dev/null
mapfile -t volumes < <(jq -r '.bindings[].volume' "$scope_file")
[[ "${#volumes[@]}" == "3" ]] || {
  echo "OpenStatus baseline backup: scope must contain exactly three volumes" >&2
  exit 1
}
for volume in "${volumes[@]}"; do
  bounded "${kubectl_command[@]}" -n "$longhorn_namespace" label volumes.longhorn.io "$volume" \
    "recurring-job.longhorn.io/${job_name}=enabled" >/dev/null
done
RUN_ID="$run_id" BACKUP_MANIFEST="$backup_manifest" \
EXPECTED_SCOPE_SHA256="$expected_scope_sha256" \
  bounded bash "$script_dir/check-openstatus-baseline-backup.sh" labels

remaining=$((deadline - $(date -u +%s)))
(( remaining > 0 )) || exit 124
bounded "${kubectl_command[@]}" -n "$longhorn_namespace" wait --for=create "cronjob/${job_name}" \
  --timeout="${remaining}s" >/dev/null
bounded "${kubectl_command[@]}" -n "$longhorn_namespace" create job --from="cronjob/${job_name}" \
  "$job_name" >/dev/null

while true; do
  set +e
  RUN_ID="$run_id" BACKUP_MANIFEST="$backup_manifest" BASELINE_FILE="$baseline_file" \
  EXPECTED_SCOPE_SHA256="$expected_scope_sha256" \
    bounded bash "$script_dir/check-openstatus-baseline-backup.sh" snapshots
  snapshot_rc=$?
  set -e
  [[ "$snapshot_rc" == "0" ]] && break
  (( $(date -u +%s) < deadline )) || {
    echo "OpenStatus baseline backup: snapshots were not ready before the maintenance deadline" >&2
    exit 124
  }
  bounded sleep 5
done

printf 'OpenStatus baseline backup: three snapshots registered; resume writers now\n'
printf 'baseline_sha256=%s\n' "$(sha256sum "$baseline_file" | awk '{print $1}')"
printf 'scope_sha256=%s\n' "$expected_scope_sha256"
printf 'job=%s/%s\n' "$longhorn_namespace" "$job_name"
