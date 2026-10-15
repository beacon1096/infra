#!/usr/bin/env bash
set -euo pipefail

run_id="${RUN_ID:-}"
baseline_file="${BASELINE_FILE:-}"
baseline_purpose="${BASELINE_PURPOSE:-post-init}"
longhorn_namespace="${LONGHORN_NAMESPACE:-storage}"

[[ "$run_id" =~ ^[a-z0-9]([a-z0-9-]{0,18}[a-z0-9])?$ ]] || {
  echo "baseline backup render: RUN_ID must be 1-20 lowercase alphanumeric/hyphen characters" >&2
  exit 2
}
[[ -r "$baseline_file" ]] || {
  echo "baseline backup render: BASELINE_FILE is required and must be readable" >&2
  exit 2
}
[[ "$baseline_purpose" == "pre-init" || "$baseline_purpose" == "post-init" ]] || {
  echo "baseline backup render: BASELINE_PURPOSE must be pre-init or post-init" >&2
  exit 2
}
for command in jq sha256sum; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "baseline backup render: $command is required" >&2
    exit 2
  }
done

state="$(jq -r '.tinybird.state // ""' "$baseline_file")"
captured_at="$(jq -r '.captured_at // ""' "$baseline_file")"
[[ "$captured_at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T ]] || {
  echo "baseline backup render: baseline captured_at is invalid" >&2
  exit 1
}
if [[ "$baseline_purpose" == "pre-init" ]]; then
  [[ "$state" == "uninitialized" ]] || {
    echo "baseline backup render: pre-init baseline must prove uninitialized" >&2
    exit 1
  }
else
  [[ "$state" == "initialized-empty" || "$state" == "ingested" ]] || {
    echo "baseline backup render: post-init baseline must be initialized-empty or ingested" >&2
    exit 1
  }
fi

baseline_sha256="$(sha256sum "$baseline_file" | awk '{print $1}')"
job_name="osb-$run_id"
cat <<EOF
apiVersion: longhorn.io/v1beta2
kind: RecurringJob
metadata:
  name: $job_name
  namespace: $longhorn_namespace
  labels:
    openstatus.beaco.works/baseline-run: $run_id
  annotations:
    openstatus.beaco.works/baseline-sha256: $baseline_sha256
    openstatus.beaco.works/baseline-captured-at: $captured_at
    openstatus.beaco.works/baseline-purpose: $baseline_purpose
spec:
  name: $job_name
  cron: "0 0 31 2 *"
  task: backup-force-create
  groups: []
  retain: 2
  concurrency: 3
  labels:
    openstatus.beaco.works/baseline-run: $run_id
    openstatus.beaco.works/baseline-purpose: $baseline_purpose
  parameters:
    full-backup-interval: "0"
EOF
