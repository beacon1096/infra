#!/usr/bin/env bash
set -euo pipefail

phase="${1:-plan}"
run_id="${RUN_ID:-}"
manifest="${BACKUP_MANIFEST:-}"
baseline_file="${BASELINE_FILE:-}"
openstatus_namespace="${OPENSTATUS_NAMESPACE:-monitoring}"
longhorn_namespace="${LONGHORN_NAMESPACE:-storage}"
expected_scope_sha256="${EXPECTED_SCOPE_SHA256:-}"
job_name="osb-$run_id"
required_pvcs=(openstatus-libsql-data openstatus-tinybird-data openstatus-workflows-data)

case "$phase" in
  plan | labels | snapshots | backups | cleanup-plan) ;;
  -h | --help)
    echo "usage: RUN_ID=... BACKUP_MANIFEST=... [BASELINE_FILE=...] check-openstatus-baseline-backup.sh {plan|labels|snapshots|backups|cleanup-plan}" >&2
    exit 0
    ;;
  *) echo "baseline backup check: unknown phase $phase" >&2; exit 2 ;;
esac
[[ "$run_id" =~ ^[a-z0-9]([a-z0-9-]{0,18}[a-z0-9])?$ ]] || {
  echo "baseline backup check: invalid RUN_ID" >&2
  exit 2
}
[[ -r "$manifest" ]] || {
  echo "baseline backup check: BACKUP_MANIFEST is required" >&2
  exit 2
}
for command in jq sha256sum date head; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "baseline backup check: $command is required" >&2
    exit 2
  }
done
kubectl_path="${OPENSTATUS_KUBECTL_BIN:-$(command -v kubectl || true)}"
[[ -n "$kubectl_path" && -r "$kubectl_path" ]] || {
  echo "baseline backup check: kubectl is required" >&2
  exit 2
}
kubectl_command=("$kubectl_path")
if [[ "$(head -c 2 -- "$kubectl_path")" == '#!' ]]; then
  kubectl_command=(bash "$kubectl_path")
fi
run_kubectl() {
  "${kubectl_command[@]}" "$@"
}

manifest_json="$(run_kubectl create --dry-run=client -f "$manifest" -o json)"
jq -e --arg run "$run_id" --arg job "$job_name" --arg ns "$longhorn_namespace" '
  .apiVersion == "longhorn.io/v1beta2" and .kind == "RecurringJob" and
  .metadata.name == $job and .metadata.namespace == $ns and
  .metadata.labels["openstatus.beaco.works/baseline-run"] == $run and
  .spec.name == $job and .spec.task == "backup-force-create" and
  .spec.groups == [] and .spec.concurrency == 3 and .spec.retain == 2 and
  .spec.cron == "0 0 31 2 *" and
  .spec.labels["openstatus.beaco.works/baseline-run"] == $run
' <<<"$manifest_json" >/dev/null || {
  echo "baseline backup check: manifest scope or safety settings are invalid" >&2
  exit 1
}

scope='[]'
for pvc in "${required_pvcs[@]}"; do
  pvc_json="$(run_kubectl -n "$openstatus_namespace" get pvc "$pvc" -o json)"
  jq -e '.status.phase == "Bound" and (.spec.volumeName | length > 0)' <<<"$pvc_json" >/dev/null || {
    echo "baseline backup check: PVC/$pvc is not Bound" >&2
    exit 1
  }
  pv="$(jq -r '.spec.volumeName' <<<"$pvc_json")"
  pv_json="$(run_kubectl get pv "$pv" -o json)"
  jq -e --arg ns "$openstatus_namespace" --arg pvc "$pvc" '
    .status.phase == "Bound" and .spec.csi.driver == "driver.longhorn.io" and
    .spec.claimRef.namespace == $ns and .spec.claimRef.name == $pvc and
    (.spec.csi.volumeHandle | length > 0)
  ' <<<"$pv_json" >/dev/null || {
    echo "baseline backup check: PV/$pv binding is not the expected Longhorn PVC" >&2
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
    echo "baseline backup check: Volume/$volume health or PVC/PV binding changed" >&2
    exit 1
  }
  scope="$(jq -c --arg pvc "$pvc" --arg pv "$pv" --arg volume "$volume" \
    '. + [{pvc:$pvc,pv:$pv,volume:$volume}]' <<<"$scope")"
done

jq -e '([.[].pv] | unique | length) == 3 and ([.[].volume] | unique | length) == 3' \
  <<<"$scope" >/dev/null || {
  echo "baseline backup check: expected three unique PV/Volume bindings" >&2
  exit 1
}
scope_canonical="$(jq -cS --arg run "$run_id" --arg job "$job_name" \
  '{run_id:$run,job:$job,bindings:.}' <<<"$scope")"
scope_sha256="$(printf '%s' "$scope_canonical" | sha256sum | awk '{print $1}')"
if [[ "$phase" != "plan" ]]; then
  [[ -n "$expected_scope_sha256" && "$expected_scope_sha256" == "$scope_sha256" ]] || {
    echo "baseline backup check: EXPECTED_SCOPE_SHA256 does not match current bindings" >&2
    exit 1
  }
fi

label_key="recurring-job.longhorn.io/$job_name"
volumes_json="$(run_kubectl -n "$longhorn_namespace" get volumes.longhorn.io -o json)"
labeled_volumes="$(jq -c --arg key "$label_key" '[.items[] | select(.metadata.labels[$key] == "enabled") | .metadata.name] | sort' <<<"$volumes_json")"
expected_volumes="$(jq -c '[.[].volume] | sort' <<<"$scope")"

if [[ "$phase" == "plan" ]]; then
  [[ "$labeled_volumes" == '[]' ]] || {
    echo "baseline backup check: temporary job label already selects a volume" >&2
    exit 1
  }
  if run_kubectl -n "$longhorn_namespace" get recurringjobs.longhorn.io "$job_name" >/dev/null 2>&1 ||
    run_kubectl -n "$longhorn_namespace" get job "$job_name" >/dev/null 2>&1; then
    echo "baseline backup check: RUN_ID collides with an existing temporary resource" >&2
    exit 1
  fi
  jq -n --arg run "$run_id" --arg job "$job_name" --arg sha "$scope_sha256" \
    --argjson bindings "$scope" '
    {run_id:$run,job:$job,scope_sha256:$sha,bindings:$bindings,
     selector:{kind:"direct recurring-job label",groups:[],selected_volume_count:3},
     stop_write_max_seconds:600,
     stop_conditions:["binding drift","extra selected volume","unhealthy volume","snapshot error","backup registration missing"]}'
  exit 0
fi

if [[ "$phase" == "cleanup-plan" ]]; then
  if ! jq -e --argjson expected "$expected_volumes" \
    'all(.[]; . as $actual | ($expected | index($actual)) != null)' \
    <<<"$labeled_volumes" >/dev/null; then
    echo "baseline backup check: temporary label selects an unexpected volume; refusing cleanup" >&2
    exit 1
  fi
  printf 'Remove label %s from:\n' "$label_key"
  jq -r '.[] | "  Volume/" + .volume' <<<"$scope"
  printf 'Delete only Job/%s, CronJob/%s and RecurringJob/%s in %s.\n' \
    "$job_name" "$job_name" "$job_name" "$longhorn_namespace"
  printf 'Preserve all Backup, Snapshot, PV, PVC and production Deployment objects.\n'
  exit 0
fi

[[ "$labeled_volumes" == "$expected_volumes" ]] || {
  echo "baseline backup check: direct job label must select exactly the three approved volumes" >&2
  exit 1
}
live_job="$(run_kubectl -n "$longhorn_namespace" get recurringjobs.longhorn.io "$job_name" -o json)"
jq -e --arg run "$run_id" '
  .spec.task == "backup-force-create" and .spec.groups == [] and
  .spec.concurrency == 3 and .spec.labels["openstatus.beaco.works/baseline-run"] == $run
' <<<"$live_job" >/dev/null || {
  echo "baseline backup check: live RecurringJob differs from the approved manifest" >&2
  exit 1
}
[[ "$phase" == "labels" ]] && {
  echo "baseline backup check: exactly three current Volume bindings selected"
  exit 0
}

[[ -r "$baseline_file" ]] || {
  echo "baseline backup check: BASELINE_FILE is required for snapshot/backup checks" >&2
  exit 2
}
captured_at="$(jq -r '.captured_at // ""' "$baseline_file")"
captured_epoch="$(date -u -d "$captured_at" +%s)"
snapshots_json="$(run_kubectl -n "$longhorn_namespace" get snapshots.longhorn.io -o json)"
selected_snapshots="$(jq -c --arg run "$run_id" --arg job "$job_name" '
  [.items[] | select(
    .spec.labels["openstatus.beaco.works/baseline-run"] == $run and
    .spec.labels.RecurringJob == $job
  )]
' <<<"$snapshots_json")"
jq -e --argjson scope "$scope" --argjson captured "$captured_epoch" '
  length == 3 and
  ([.[].spec.volume] | sort) == ([$scope[].volume] | sort) and
  all(.[]; .status.readyToUse == true and (.status.error // "") == "" and
    ((.status.creationTime | fromdateiso8601) >= $captured))
' <<<"$selected_snapshots" >/dev/null || {
  echo "baseline backup check: exact three baseline-linked snapshots are not ready" >&2
  exit 1
}
backups_json="$(run_kubectl -n "$longhorn_namespace" get backups.longhorn.io -o json)"
registered_backups="$(jq -c --arg run "$run_id" '[.items[] | select(.spec.labels["openstatus.beaco.works/baseline-run"] == $run)]' <<<"$backups_json")"
jq -e --argjson scope "$scope" --argjson snapshots "$selected_snapshots" '
  length == 3 and
  ([.[].status.volumeName] | sort) == ([$scope[].volume] | sort) and
  ([.[].status.snapshotName] | sort) == ([$snapshots[].metadata.name] | sort) and
  all(.[]; (.status.state == "InProgress" or .status.state == "Completed") and
    (.status.error // "") == "")
' <<<"$registered_backups" >/dev/null || {
  echo "baseline backup check: exact three snapshot backups are not registered" >&2
  exit 1
}
[[ "$phase" == "snapshots" ]] && {
  echo "baseline backup check: exact three snapshots are ready and backups registered; writers may be resumed"
  exit 0
}

jq -e --argjson scope "$scope" --argjson snapshots "$selected_snapshots" --arg run "$run_id" --argjson captured "$captured_epoch" '
  [.items[] | select(.spec.labels["openstatus.beaco.works/baseline-run"] == $run)] as $selected |
  ($selected | length) == 3 and
  ([$selected[].status.volumeName] | sort) == ([$scope[].volume] | sort) and
  ([$selected[].status.snapshotName] | sort) == ([$snapshots[].metadata.name] | sort) and
  all($selected[]; .status.state == "Completed" and (.status.error // "") == "" and
    .status.progress == 100 and ((.status.snapshotCreatedAt | fromdateiso8601) >= $captured) and
    (.status.url | length > 0))
' <<<"$backups_json" >/dev/null || {
  echo "baseline backup check: exact three backups are not completed and baseline-linked" >&2
  exit 1
}
echo "baseline backup check: exact three backups completed; no default-group result was counted"
