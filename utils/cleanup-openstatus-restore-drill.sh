#!/usr/bin/env bash
set -euo pipefail

run_id="${RUN_ID:-}"
restore_manifest="${RESTORE_MANIFEST:-}"
expected_manifest_sha256="${EXPECTED_MANIFEST_SHA256:-}"
execute=false
longhorn_namespace="${LONGHORN_NAMESPACE:-storage}"
restore_namespace="openstatus-restore-${run_id}"
restore_label="openstatus.beaco.works/restore-run"
components=(libsql tinybird workflows)

usage() {
  cat >&2 <<'EOF'
Plan or execute cleanup for one rendered OpenStatus restore drill.

Usage:
  RUN_ID=20261015a RESTORE_MANIFEST=./openstatus-restore-20261015a.yaml \
    bash utils/cleanup-openstatus-restore-drill.sh --plan

  RUN_ID=20261015a RESTORE_MANIFEST=./openstatus-restore-20261015a.yaml \
    EXPECTED_MANIFEST_SHA256=<approved-sha256> CONFIRM_RUN_ID=20261015a \
    bash utils/cleanup-openstatus-restore-drill.sh --execute

Plan validates the exact manifest even before any resource exists. Both modes
allow a partially-created run, but refuse unexpected names, labels, bindings,
CSI handles, storage classes, or a PV reclaim policy other than Retain.
EOF
}

case "${1:---plan}" in
  --plan) ;;
  --execute) execute=true ;;
  -h|--help) usage; exit 0 ;;
  *) usage; exit 2 ;;
esac

[[ "$run_id" =~ ^[a-z0-9]([a-z0-9-]{0,22}[a-z0-9])?$ ]] || {
  echo "cleanup: RUN_ID must be 1-24 lowercase DNS-label characters" >&2
  exit 2
}
[[ -r "$restore_manifest" ]] || {
  echo "cleanup: RESTORE_MANIFEST is required and must be readable" >&2
  exit 2
}
for command in kubectl jq sha256sum awk; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "cleanup: $command is required" >&2
    exit 2
  }
done

manifest_sha256="$(sha256sum "$restore_manifest" | awk '{print $1}')"
if [[ -n "$expected_manifest_sha256" && "$manifest_sha256" != "$expected_manifest_sha256" ]]; then
  echo "cleanup: manifest SHA-256 differs from EXPECTED_MANIFEST_SHA256" >&2
  exit 1
fi
if [[ "$execute" == true && ! "$expected_manifest_sha256" =~ ^[0-9a-f]{64}$ ]]; then
  echo "cleanup: --execute requires the approved EXPECTED_MANIFEST_SHA256" >&2
  exit 2
fi

manifest_json="$(kubectl create --dry-run=client -f "$restore_manifest" -o json | jq -s '{items: .}')"
jq -e --arg namespace "$restore_namespace" --arg key "$restore_label" --arg run "$run_id" '
  ([.items[] | select(.kind == "Namespace" and .metadata.name == $namespace and .metadata.labels[$key] == $run)] | length) == 1 and
  ([.items[] | select(.kind == "PersistentVolume" and .metadata.labels[$key] == $run)] | length) == 3 and
  ([.items[] | select(.kind == "Volume" and .apiVersion == "longhorn.io/v1beta2" and .metadata.labels[$key] == $run)] | length) == 3
' <<<"$manifest_json" >/dev/null || {
  echo "cleanup: manifest lacks the exact namespace or three expected PV/Longhorn volume objects" >&2
  exit 1
}
for component in "${components[@]}"; do
  volume="osr-${run_id}-${component}"
  pvc="restore-${component}-data"
  jq -e \
    --arg namespace "$restore_namespace" \
    --arg storage_namespace "$longhorn_namespace" \
    --arg key "$restore_label" \
    --arg run "$run_id" \
    --arg volume "$volume" \
    --arg pvc "$pvc" '
    any(.items[];
      .kind == "Volume" and .apiVersion == "longhorn.io/v1beta2" and
      .metadata.namespace == $storage_namespace and .metadata.name == $volume and
      .metadata.labels[$key] == $run) and
    any(.items[];
      .kind == "PersistentVolume" and .metadata.name == $volume and
      .metadata.labels[$key] == $run and
      .spec.persistentVolumeReclaimPolicy == "Retain" and
      .spec.storageClassName == "longhorn" and
      .spec.claimRef.namespace == $namespace and .spec.claimRef.name == $pvc and
      .spec.csi.driver == "driver.longhorn.io" and .spec.csi.volumeHandle == $volume) and
    any(.items[];
      .kind == "PersistentVolumeClaim" and
      .metadata.namespace == $namespace and .metadata.name == $pvc and
      .metadata.labels[$key] == $run and
      .spec.storageClassName == "longhorn" and .spec.volumeName == $volume)
  ' <<<"$manifest_json" >/dev/null || {
    echo "cleanup: manifest binding validation failed for $component" >&2
    exit 1
  }
done

namespace_exists=false
namespace_json=""
if namespace_json="$(kubectl get namespace "$restore_namespace" -o json 2>/dev/null)"; then
  namespace_exists=true
  jq -e --arg key "$restore_label" --arg value "$run_id" --arg namespace "$restore_namespace" \
    '.metadata.name == $namespace and .metadata.labels[$key] == $value' \
    <<<"$namespace_json" >/dev/null || {
    echo "cleanup: refusing; Namespace/$restore_namespace lacks the exact run label" >&2
    exit 1
  }
fi

pv_set_json="$(kubectl get pv -l "$restore_label=$run_id" -o json)"
volume_set_json="$(kubectl -n "$longhorn_namespace" get volumes.longhorn.io \
  -l "$restore_label=$run_id" -o json)"
jq -e --arg run "$run_id" '
  all(.items[].metadata.name; . == "osr-\($run)-libsql" or . == "osr-\($run)-tinybird" or . == "osr-\($run)-workflows")
' <<<"$pv_set_json" >/dev/null || {
  echo "cleanup: refusing; an unexpected PV carries the run label" >&2
  exit 1
}
jq -e --arg run "$run_id" '
  all(.items[].metadata.name; . == "osr-\($run)-libsql" or . == "osr-\($run)-tinybird" or . == "osr-\($run)-workflows")
' <<<"$volume_set_json" >/dev/null || {
  echo "cleanup: refusing; an unexpected Longhorn volume carries the run label" >&2
  exit 1
}

declare -a present_pvs=() present_volumes=()
for component in "${components[@]}"; do
  volume="osr-${run_id}-${component}"
  pvc="restore-${component}-data"
  if pv_json="$(kubectl get pv "$volume" -o json 2>/dev/null)"; then
    jq -e \
      --arg namespace "$restore_namespace" --arg pvc "$pvc" \
      --arg key "$restore_label" --arg run "$run_id" --arg volume "$volume" '
      .metadata.name == $volume and .metadata.labels[$key] == $run and
      .spec.persistentVolumeReclaimPolicy == "Retain" and
      .spec.storageClassName == "longhorn" and
      .spec.claimRef.namespace == $namespace and .spec.claimRef.name == $pvc and
      .spec.csi.driver == "driver.longhorn.io" and .spec.csi.volumeHandle == $volume
    ' <<<"$pv_json" >/dev/null || {
      echo "cleanup: refusing; PV/$volume binding or Retain policy differs from the manifest" >&2
      exit 1
    }
    present_pvs+=("$volume")
  fi
  if longhorn_json="$(kubectl -n "$longhorn_namespace" get volumes.longhorn.io "$volume" -o json 2>/dev/null)"; then
    jq -e --arg key "$restore_label" --arg run "$run_id" --arg volume "$volume" '
      .metadata.name == $volume and .metadata.labels[$key] == $run
    ' <<<"$longhorn_json" >/dev/null || {
      echo "cleanup: refusing; Longhorn Volume/$volume differs from the manifest identity" >&2
      exit 1
    }
    present_volumes+=("$volume")
  fi
  if [[ "$namespace_exists" == true ]] && pvc_json="$(kubectl -n "$restore_namespace" get pvc "$pvc" -o json 2>/dev/null)"; then
    jq -e --arg key "$restore_label" --arg run "$run_id" --arg volume "$volume" --arg pvc "$pvc" '
      .metadata.name == $pvc and .metadata.labels[$key] == $run and
      .spec.storageClassName == "longhorn" and .spec.volumeName == $volume
    ' <<<"$pvc_json" >/dev/null || {
      echo "cleanup: refusing; PVC/$pvc does not bind the expected PV" >&2
      exit 1
    }
  fi
done

echo "Cleanup plan for restore run $run_id (manifest SHA-256 $manifest_sha256):"
if [[ "$namespace_exists" == true ]]; then
  printf '  namespace/%s (present)\n' "$restore_namespace"
else
  printf '  namespace/%s (absent)\n' "$restore_namespace"
fi
for component in "${components[@]}"; do
  volume="osr-${run_id}-${component}"
  pv_state=absent
  volume_state=absent
  [[ " ${present_pvs[*]} " == *" $volume "* ]] && pv_state=present
  [[ " ${present_volumes[*]} " == *" $volume "* ]] && volume_state=present
  printf '  persistentvolume/%s (%s, Retain binding verified when present)\n' "$volume" "$pv_state"
  printf '  longhorn-volume/%s (%s)\n' "$volume" "$volume_state"
done
echo "Source Backup objects, source Longhorn volumes, monitoring PVCs, and Secrets are not selected."

if [[ "$execute" == false ]]; then
  echo "cleanup: plan only; partial or absent creation is safe and requires no deletion"
  exit 0
fi
[[ "${CONFIRM_RUN_ID:-}" == "$run_id" ]] || {
  echo "cleanup: CONFIRM_RUN_ID must exactly equal RUN_ID for --execute" >&2
  exit 2
}

if [[ "$namespace_exists" == true ]]; then
  kubectl delete namespace "$restore_namespace" --wait=true --timeout=10m
fi
for pv in "${present_pvs[@]}"; do
  kubectl delete pv "$pv" --wait=true --timeout=2m
done
for volume in "${present_volumes[@]}"; do
  kubectl -n "$longhorn_namespace" delete volumes.longhorn.io "$volume" \
    --wait=true --timeout=5m
done

for component in "${components[@]}"; do
  volume="osr-${run_id}-${component}"
  if kubectl get pv "$volume" >/dev/null 2>&1 ||
    kubectl -n "$longhorn_namespace" get volumes.longhorn.io "$volume" >/dev/null 2>&1; then
    echo "cleanup: expected resource $volume remains; stop before any broader deletion" >&2
    exit 1
  fi
done
if kubectl get namespace "$restore_namespace" >/dev/null 2>&1; then
  echo "cleanup: Namespace/$restore_namespace remains" >&2
  exit 1
fi
echo "cleanup: removed only the present resources from restore run $run_id"
