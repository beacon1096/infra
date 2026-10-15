#!/usr/bin/env bash
set -euo pipefail

run_id="${RUN_ID:-}"
execute=false
longhorn_namespace="${LONGHORN_NAMESPACE:-storage}"
restore_namespace="openstatus-restore-${run_id}"
restore_label="openstatus.beaco.works/restore-run"

if [[ "${1:-}" == "--execute" ]]; then
  execute=true
elif [[ -n "${1:-}" && "${1:-}" != "--plan" ]]; then
  echo "cleanup: expected --plan (default) or --execute" >&2
  exit 2
fi

[[ "$run_id" =~ ^[a-z0-9]([a-z0-9-]{0,22}[a-z0-9])?$ ]] || {
  echo "cleanup: RUN_ID must be 1-24 lowercase DNS-label characters" >&2
  exit 2
}
for command in kubectl jq; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "cleanup: $command is required" >&2
    exit 2
  }
done

namespace_json="$(kubectl get namespace "$restore_namespace" -o json)"
jq -e --arg key "$restore_label" --arg value "$run_id" \
  '.metadata.labels[$key] == $value' <<<"$namespace_json" >/dev/null || {
  echo "cleanup: refusing; Namespace/$restore_namespace lacks the exact run label" >&2
  exit 1
}

pv_json="$(kubectl get pv -l "$restore_label=$run_id" -o json)"
volume_json="$(kubectl -n "$longhorn_namespace" get volumes.longhorn.io \
  -l "$restore_label=$run_id" -o json)"

jq -e --arg key "$restore_label" --arg value "$run_id" '
  (.items | length) == 3 and all(.items[]; .metadata.labels[$key] == $value)
' <<<"$pv_json" >/dev/null || {
  echo "cleanup: refusing; expected exactly three exactly-labeled PVs" >&2
  exit 1
}
jq -e --arg key "$restore_label" --arg value "$run_id" '
  (.items | length) == 3 and all(.items[]; .metadata.labels[$key] == $value)
' <<<"$volume_json" >/dev/null || {
  echo "cleanup: refusing; expected exactly three exactly-labeled Longhorn volumes" >&2
  exit 1
}

echo "Cleanup plan for restore run $run_id:"
printf '  namespace/%s (exact label verified)\n' "$restore_namespace"
jq -r '.items[].metadata.name | "  persistentvolume/" + .' <<<"$pv_json"
jq -r '.items[].metadata.name | "  longhorn-volume/" + .' <<<"$volume_json"
echo "Source Backup objects, source Longhorn volumes, and monitoring PVCs are not selected."

if [[ "$execute" == false ]]; then
  echo "cleanup: plan only; use --execute with CONFIRM_RUN_ID=$run_id after evidence is saved"
  exit 0
fi
[[ "${CONFIRM_RUN_ID:-}" == "$run_id" ]] || {
  echo "cleanup: CONFIRM_RUN_ID must exactly equal RUN_ID for --execute" >&2
  exit 2
}

mapfile -t pv_names < <(jq -r '.items[].metadata.name' <<<"$pv_json")
mapfile -t volume_names < <(jq -r '.items[].metadata.name' <<<"$volume_json")

kubectl delete namespace "$restore_namespace" --wait=true --timeout=10m
for pv in "${pv_names[@]}"; do
  kubectl delete pv "$pv" --wait=true --timeout=2m
done
for volume in "${volume_names[@]}"; do
  kubectl -n "$longhorn_namespace" delete volumes.longhorn.io "$volume" \
    --wait=true --timeout=5m
done

if kubectl get pv -l "$restore_label=$run_id" -o name | grep -q . ||
  kubectl -n "$longhorn_namespace" get volumes.longhorn.io \
    -l "$restore_label=$run_id" -o name | grep -q .; then
  echo "cleanup: labeled resources remain; stop and inspect before any further deletion" >&2
  exit 1
fi
echo "cleanup: removed only resources labeled for restore run $run_id"
