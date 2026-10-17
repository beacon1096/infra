#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
quiesce_script="$script_dir/quiesce-openstatus-writers.sh"
window_seconds="${OPENSTATUS_MAINTENANCE_WINDOW_SECONDS:-600}"

usage() {
  cat >&2 <<'EOF'
Usage:
  REPLICA_STATE_FILE=... EXPECTED_REPLICA_STATE_SHA256=... \
    bash utils/with-openstatus-quiesced.sh -- command [args...]

Installs the recovery trap before the quiesce helper's first mutation. When
the payload is start-openstatus-baseline-backup.sh, that script's read-only
identity and deadline checks run before ownership or the first mutation.
The work window defaults to 600 seconds and can be set from 1 to 600 with
OPENSTATUS_MAINTENANCE_WINDOW_SECONDS. It bounds writer stop and the payload
through snapshot ready and Backup registration. It does not include upload or
the Completed check, and it does not mean services are back at 600 seconds.

Replica and Flux restoration runs after success, failure, timeout, SIGINT, and
SIGTERM. That restoration has a separate budget, OPENSTATUS_RECOVERY_MAX_SECONDS,
default 300 and allowed 30-600. If the API stays unreachable or a Pod does not
become Ready inside that budget, restoration fails closed and leaves ownership
at acquired. The trap does not remove temporary backup labels or jobs; those
remain an explicit cleanup obligation for the same run. This wrapper does not
itself initialize Tinybird.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

[[ "${1:-}" == "--" ]] || {
  usage
  exit 2
}
shift
(( $# > 0 )) || {
  usage
  exit 2
}
[[ "$window_seconds" =~ ^[0-9]+$ ]] &&
  (( window_seconds >= 1 && window_seconds <= 600 )) || {
  echo "OpenStatus maintenance window: duration must be 1-600 seconds" >&2
  exit 2
}
for command in bash date timeout jq realpath; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "OpenStatus maintenance window: $command is required" >&2
    exit 2
  }
done
[[ -r "$quiesce_script" ]] || {
  echo "OpenStatus maintenance window: quiesce helper is missing" >&2
  exit 2
}
[[ -n "${REPLICA_STATE_FILE:-}" && -n "${EXPECTED_REPLICA_STATE_SHA256:-}" ]] || {
  echo "OpenStatus maintenance window: replica state file and SHA-256 are required" >&2
  exit 2
}

state_file_absolute="$(realpath -- "$REPLICA_STATE_FILE")"
ownership_file="${OPENSTATUS_QUIESCE_OWNERSHIP_FILE:-${state_file_absolute}.quiesce-ownership.json}"
ownership_file="$(realpath -m -- "$ownership_file")"
[[ ! -e "$ownership_file" ]] || {
  echo "OpenStatus maintenance window: ownership marker already exists; use its recorded state for recovery or create a new plan" >&2
  exit 1
}

QUIESCE_DEADLINE_EPOCH=$(( $(date -u +%s) + window_seconds ))
OPENSTATUS_WINDOW_PID="$$"
OPENSTATUS_QUIESCE_OWNERSHIP_FILE="$ownership_file"
export QUIESCE_DEADLINE_EPOCH OPENSTATUS_WINDOW_PID OPENSTATUS_QUIESCE_OWNERSHIP_FILE
recovery_attempted=false

ownership_phase() {
  [[ -r "$ownership_file" ]] || return 1
  jq -er --arg sha "$EXPECTED_REPLICA_STATE_SHA256" '
    select(.schema_version == 1 and .state_sha256 == $sha) | .phase |
    select(. == "acquired" or . == "recovered")
  ' "$ownership_file"
}

resume_once() {
  local phase resume_rc
  [[ "$recovery_attempted" == "false" ]] || return 0
  phase="$(ownership_phase)" || {
    echo "OpenStatus maintenance window: refusing recovery without this plan's valid ownership marker" >&2
    return 1
  }
  [[ "$phase" == "acquired" ]] || return 0
  # The helper owns any retry needed inside this one recovery attempt. Marking
  # the outer attempt first prevents its EXIT trap from invoking a second,
  # stale recovery after the helper has returned.
  recovery_attempted=true
  set +e
  bash "$quiesce_script" --resume
  resume_rc=$?
  set -e
  return "$resume_rc"
}

restore_on_exit() {
  local rc=$?
  local phase="" resume_rc=0
  trap - EXIT INT TERM
  phase="$(ownership_phase 2>/dev/null || true)"
  if [[ "$phase" == "acquired" && "$recovery_attempted" == "false" ]]; then
    echo "OpenStatus maintenance window: leaving payload; restoring replicas and Flux" >&2
    resume_once || resume_rc=$?
  elif [[ -e "$ownership_file" && -z "$phase" ]]; then
    echo "OpenStatus maintenance window: ownership marker is invalid; refusing blind recovery" >&2
    resume_rc=1
  fi
  if (( rc == 0 && resume_rc != 0 )); then
    rc="$resume_rc"
  fi
  exit "$rc"
}
trap restore_on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

run_known_payload_preflight() {
  local arg found=0
  local -a command=()
  for arg in "$@"; do
    command+=("$arg")
    if [[ "$found" == "0" && "$arg" == *start-openstatus-baseline-backup.sh ]]; then
      command+=("--preflight")
      found=1
    fi
  done
  (( found )) || return 0
  "${command[@]}"
}
run_known_payload_preflight "$@"

remaining=$((QUIESCE_DEADLINE_EPOCH - $(date -u +%s)))
(( remaining > 0 )) || {
  echo "OpenStatus maintenance window: deadline expired before the first mutation" >&2
  exit 124
}
bash "$quiesce_script" --stop

remaining=$((QUIESCE_DEADLINE_EPOCH - $(date -u +%s)))
(( remaining > 0 )) || {
  echo "OpenStatus maintenance window: deadline expired before payload" >&2
  exit 124
}
timeout --foreground --kill-after=5s "${remaining}s" "$@"

resume_once
[[ "$(ownership_phase)" == "recovered" ]] || {
  echo "OpenStatus maintenance window: helper returned without completing recovery ownership" >&2
  exit 1
}
trap - EXIT INT TERM
echo "OpenStatus maintenance window: payload finished inside the ${window_seconds}s work window and replica/Flux recovery completed on its separate budget"
