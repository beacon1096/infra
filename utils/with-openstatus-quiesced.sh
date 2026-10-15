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

Installs the recovery trap and the one maintenance deadline before asking the
quiesce helper to make its first change. The command and every stop operation
share that deadline. Replica and Flux restoration runs on success, error,
timeout, SIGINT and SIGTERM.
EOF
}

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
for command in bash date timeout; do
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

QUIESCE_DEADLINE_EPOCH=$(( $(date -u +%s) + window_seconds ))
OPENSTATUS_WINDOW_PID="$$"
export QUIESCE_DEADLINE_EPOCH OPENSTATUS_WINDOW_PID
resume_pending=true

resume_once() {
  local resume_rc
  [[ "$resume_pending" == "true" ]] || return 0
  # Set this before invoking the helper: it has its own retry trap if recovery
  # is interrupted, and the outer EXIT trap must not recursively invoke it.
  resume_pending=false
  set +e
  bash "$quiesce_script" --resume
  resume_rc=$?
  set -e
  return "$resume_rc"
}

restore_on_exit() {
  local rc=$?
  local resume_rc=0
  trap - EXIT INT TERM
  if [[ "$resume_pending" == "true" ]]; then
    echo "OpenStatus maintenance window: leaving payload; restoring replicas and Flux" >&2
    resume_once || resume_rc=$?
  fi
  if (( rc == 0 && resume_rc != 0 )); then
    rc="$resume_rc"
  fi
  exit "$rc"
}
trap restore_on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

bash "$quiesce_script" --stop

remaining=$((QUIESCE_DEADLINE_EPOCH - $(date -u +%s)))
(( remaining > 0 )) || {
  echo "OpenStatus maintenance window: deadline expired before payload" >&2
  exit 124
}
timeout --foreground --kill-after=5s "${remaining}s" "$@"

resume_once
trap - EXIT INT TERM
echo "OpenStatus maintenance window: payload completed inside ${window_seconds}s and recovery completed"
