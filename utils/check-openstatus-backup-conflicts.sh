#!/usr/bin/env bash
set -euo pipefail

openstatus_namespace="${OPENSTATUS_NAMESPACE:-monitoring}"
longhorn_namespace="${LONGHORN_NAMESPACE:-storage}"
daily_job_name="${OPENSTATUS_DAILY_BACKUP_JOB:-daily-backup}"
required_pvcs=(openstatus-libsql-data openstatus-tinybird-data openstatus-workflows-data)

for command in date head jq; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "OpenStatus backup conflict check: $command is required" >&2
    exit 2
  }
done
kubectl_path="${OPENSTATUS_KUBECTL_BIN:-$(command -v kubectl || true)}"
[[ -n "$kubectl_path" && -r "$kubectl_path" ]] || {
  echo "OpenStatus backup conflict check: kubectl is required" >&2
  exit 2
}
kubectl_command=("$kubectl_path")
if [[ "$(head -c 2 -- "$kubectl_path")" == '#!' ]]; then
  kubectl_command=(bash "$kubectl_path")
fi
run_kubectl() {
  "${kubectl_command[@]}" "$@"
}

bindings='[]'
stale_direct_labels='[]'
for pvc in "${required_pvcs[@]}"; do
  pvc_json="$(run_kubectl -n "$openstatus_namespace" get pvc "$pvc" -o json)"
  jq -e '.status.phase == "Bound" and (.spec.volumeName | length > 0)' \
    <<<"$pvc_json" >/dev/null || {
    echo "OpenStatus backup conflict check: PVC/$pvc is not Bound" >&2
    exit 1
  }
  pv="$(jq -r '.spec.volumeName' <<<"$pvc_json")"
  pv_json="$(run_kubectl get pv "$pv" -o json)"
  jq -e --arg ns "$openstatus_namespace" --arg pvc "$pvc" '
    .status.phase == "Bound" and .spec.csi.driver == "driver.longhorn.io" and
    .spec.claimRef.namespace == $ns and .spec.claimRef.name == $pvc and
    (.spec.csi.volumeHandle | length > 0)
  ' <<<"$pv_json" >/dev/null || {
    echo "OpenStatus backup conflict check: PV/$pv binding is not the expected Longhorn PVC" >&2
    exit 1
  }
  volume="$(jq -r '.spec.csi.volumeHandle' <<<"$pv_json")"
  volume_json="$(run_kubectl -n "$longhorn_namespace" get volumes.longhorn.io "$volume" -o json)"
  jq -e --arg ns "$openstatus_namespace" --arg pvc "$pvc" --arg pv "$pv" '
    .metadata.name != "" and .status.robustness == "healthy" and
    .status.state == "attached" and
    .status.kubernetesStatus.namespace == $ns and
    .status.kubernetesStatus.pvcName == $pvc and
    .status.kubernetesStatus.pvName == $pv
  ' <<<"$volume_json" >/dev/null || {
    echo "OpenStatus backup conflict check: Volume/$volume health or PVC/PV binding changed" >&2
    exit 1
  }
  bindings="$(jq -c --arg pvc "$pvc" --arg pv "$pv" --arg volume "$volume" \
    '. + [{pvc:$pvc,pv:$pv,volume:$volume}]' <<<"$bindings")"
  volume_labels="$(jq -c --arg prefix 'recurring-job.longhorn.io/osb-' '
    [(.metadata.labels // {}) | to_entries[] |
      select((.key | startswith($prefix)) and .value == "enabled") |
      {label:.key,value:.value}]
  ' <<<"$volume_json")"
  stale_direct_labels="$(jq -c --arg volume "$volume" --argjson labels "$volume_labels" \
    '. + [$labels[] | . + {volume:$volume}]' <<<"$stale_direct_labels")"
done

target_volumes="$(jq -c '[.[].volume]' <<<"$bindings")"
jobs_json="$(run_kubectl -n "$longhorn_namespace" get jobs -o json)"
active_jobs="$(jq -c --arg daily "$daily_job_name" --arg prefix 'osb-' '
  [.items[] |
    ((.metadata.ownerReferences // []) |
      map(select(.kind == "CronJob")) | .[0].name // "") as $owner |
    select($owner == $daily or ($owner | startswith($prefix))) |
    select((.status.active // 0) > 0) |
    {name:.metadata.name,owner:$owner,active:.status.active,
     startTime:(.status.startTime // "")}]
' <<<"$jobs_json")"

backups_json="$(run_kubectl -n "$longhorn_namespace" get backups.longhorn.io -o json)"
active_target_backups="$(jq -c --argjson targets "$target_volumes" '
  [.items[] |
    (.metadata.labels["backup-volume"] // .status.volumeName // "") as $volume |
    (.status.state // "") as $state |
    select(($targets | index($volume)) != null) |
    select($state == "" or $state == "New" or $state == "Pending" or $state == "InProgress") |
    {name:.metadata.name,volume:$volume,state:$state,
     progress:(.status.progress // null),snapshotName:(.spec.snapshotName // "")}]
' <<<"$backups_json")"

checked_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
result="$(jq -n --arg checked_at "$checked_at" --arg daily "$daily_job_name" \
  --argjson bindings "$bindings" --argjson jobs "$active_jobs" \
  --argjson backups "$active_target_backups" --argjson labels "$stale_direct_labels" '
  {checked_at:$checked_at,daily_job:$daily,target_bindings:$bindings,
   active_conflicting_jobs:$jobs,active_target_backups:$backups,
   stale_direct_labels:$labels}
')"
printf '%s\n' "$result" | jq .

jq -e '
  (.active_conflicting_jobs | length) == 0 and
  (.active_target_backups | length) == 0 and
  (.stale_direct_labels | length) == 0
' <<<"$result" >/dev/null || {
  echo "OpenStatus backup conflict check: active or stale backup work blocks the three-volume run" >&2
  exit 1
}

echo "OpenStatus backup conflict check: no active daily/three-volume job, target backup, or stale direct label" >&2
