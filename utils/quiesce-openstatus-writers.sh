#!/usr/bin/env bash
set -euo pipefail

mode="${1:---plan}"
namespace="${OPENSTATUS_NAMESPACE:-monitoring}"
run_id="${RUN_ID:-}"
state_file="${REPLICA_STATE_FILE:-}"
expected_sha256="${EXPECTED_REPLICA_STATE_SHA256:-}"
writers=(
  openstatus-server
  openstatus-workflows
  openstatus-checker
  openstatus-private-location
  openstatus-probe-wanxiang
)

case "$mode" in
  --plan | --stop | --resume) ;;
  -h | --help)
    echo "usage: REPLICA_STATE_FILE=... quiesce-openstatus-writers.sh {--plan|--stop|--resume}" >&2
    exit 0
    ;;
  *) echo "OpenStatus quiesce: unknown mode $mode" >&2; exit 2 ;;
esac
for command in kubectl jq sha256sum; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "OpenStatus quiesce: $command is required" >&2
    exit 2
  }
done

if [[ "$mode" == "--plan" ]]; then
  [[ "$run_id" =~ ^[a-z0-9]([a-z0-9-]{0,18}[a-z0-9])?$ ]] || {
    echo "OpenStatus quiesce: RUN_ID must be 1-20 lowercase alphanumeric/hyphen characters" >&2
    exit 2
  }
  flux_json="$(kubectl -n "$namespace" get kustomization.kustomize.toolkit.fluxcd.io openstatus -o json)"
  jq -e '
    (.spec.suspend // false) == false and
    any(.status.conditions[]?; .type == "Ready" and .status == "True") and
    (.status.lastAppliedRevision | length > 0)
  ' <<<"$flux_json" >/dev/null || {
    echo "OpenStatus quiesce: Flux must be Ready and not suspended" >&2
    exit 1
  }
  replicas='[]'
  for deployment in "${writers[@]}"; do
    deployment_json="$(kubectl -n "$namespace" get deployment "$deployment" -o json)" || {
      echo "OpenStatus quiesce: Deployment/$deployment is missing" >&2
      exit 1
    }
    replicas="$(jq -c --arg name "$deployment" --argjson replicas "$(jq -r '.spec.replicas // 1' <<<"$deployment_json")" \
      '. + [{name:$name,replicas:$replicas}]' <<<"$replicas")"
  done
  workflows_pods="$(kubectl -n "$namespace" get pod \
    -l app.kubernetes.io/name=openstatus-workflows -o json)"
  workflows_image_id="$(jq -r '
    [.items[] | select(.status.phase == "Running") |
      .status.containerStatuses[] | select(.name == "workflows") | .imageID] |
    if length == 1 then .[0] else "" end
  ' <<<"$workflows_pods")"
  [[ "$workflows_image_id" == *@sha256:* ]] || {
    echo "OpenStatus quiesce: exactly one running workflows image digest is required" >&2
    exit 1
  }
  holder_name="openstatus-backup-holder-$run_id"
  if kubectl -n "$namespace" get pod "$holder_name" >/dev/null 2>&1; then
    echo "OpenStatus quiesce: Pod/$holder_name already exists" >&2
    exit 1
  fi
  jq -n --arg namespace "$namespace" \
    --arg run_id "$run_id" \
    --arg revision "$(jq -r '.status.lastAppliedRevision' <<<"$flux_json")" \
    --arg holder_name "$holder_name" \
    --arg holder_image "$workflows_image_id" \
    --argjson replicas "$replicas" '
    {schema_version:1,run_id:$run_id,namespace:$namespace,
     flux:{name:"openstatus",revision:$revision,suspend:false},writers:$replicas,
     holder:{name:$holder_name,image:$holder_image,pvc:"openstatus-workflows-data",read_only:true,max_seconds:900},
     maintenance_window_seconds:600}'
  exit 0
fi

[[ -r "$state_file" ]] || {
  echo "OpenStatus quiesce: REPLICA_STATE_FILE is required" >&2
  exit 2
}
state_sha256="$(sha256sum "$state_file" | awk '{print $1}')"
[[ -n "$expected_sha256" && "$state_sha256" == "$expected_sha256" ]] || {
  echo "OpenStatus quiesce: EXPECTED_REPLICA_STATE_SHA256 does not match" >&2
  exit 1
}
jq -e --arg namespace "$namespace" --argjson expected "$(printf '%s\n' "${writers[@]}" | jq -R . | jq -s .)" '
  .schema_version == 1 and .namespace == $namespace and
  (.run_id | test("^[a-z0-9]([a-z0-9-]{0,18}[a-z0-9])?$")) and
  .flux.name == "openstatus" and .flux.suspend == false and
  .maintenance_window_seconds == 600 and
  ([.writers[].name] == $expected) and
  all(.writers[]; (.replicas | type == "number") and .replicas >= 0) and
  .holder.name == ("openstatus-backup-holder-" + .run_id) and
  (.holder.image | test("@sha256:[0-9a-f]{64}$")) and
  .holder.pvc == "openstatus-workflows-data" and .holder.read_only == true and
  .holder.max_seconds == 900
' "$state_file" >/dev/null || {
  echo "OpenStatus quiesce: replica state file is invalid or incomplete" >&2
  exit 1
}

holder_name="$(jq -r '.holder.name' "$state_file")"
holder_image="$(jq -r '.holder.image' "$state_file")"
state_run_id="$(jq -r '.run_id' "$state_file")"

delete_holder() {
  local holder_json
  if ! holder_json="$(kubectl -n "$namespace" get pod "$holder_name" -o json 2>/dev/null)"; then
    return 0
  fi
  jq -e --arg run "$state_run_id" '
    .metadata.labels["openstatus.beaco.works/baseline-run"] == $run and
    .spec.volumes == [{name:"workflows",persistentVolumeClaim:{claimName:"openstatus-workflows-data",readOnly:true}}]
  ' <<<"$holder_json" >/dev/null || {
    echo "OpenStatus quiesce: refusing to delete unexpected Pod/$holder_name" >&2
    return 1
  }
  kubectl -n "$namespace" delete pod "$holder_name" --wait=true >/dev/null
}

restore_after_failed_stop() {
  local rc=$?
  trap - EXIT
  echo "OpenStatus quiesce: stop failed; restoring recorded state" >&2
  delete_holder || true
  for deployment in "${writers[@]}"; do
    replicas="$(jq -r --arg name "$deployment" '.writers[] | select(.name == $name) | .replicas' "$state_file")"
    kubectl -n "$namespace" scale deployment "$deployment" --replicas="$replicas" >/dev/null 2>&1 || true
  done
  kubectl -n "$namespace" patch kustomization.kustomize.toolkit.fluxcd.io openstatus \
    --type=merge -p '{"spec":{"suspend":false}}' >/dev/null 2>&1 || true
  exit "$rc"
}

if [[ "$mode" == "--stop" ]]; then
  flux_json="$(kubectl -n "$namespace" get kustomization.kustomize.toolkit.fluxcd.io openstatus -o json)"
  jq -e --arg revision "$(jq -r '.flux.revision' "$state_file")" '
    (.spec.suspend // false) == false and .status.lastAppliedRevision == $revision and
    any(.status.conditions[]?; .type == "Ready" and .status == "True")
  ' <<<"$flux_json" >/dev/null || {
    echo "OpenStatus quiesce: Flux state or revision changed since the plan" >&2
    exit 1
  }
  for deployment in "${writers[@]}"; do
    current="$(kubectl -n "$namespace" get deployment "$deployment" -o jsonpath='{.spec.replicas}')"
    expected="$(jq -r --arg name "$deployment" '.writers[] | select(.name == $name) | .replicas' "$state_file")"
    [[ "$current" == "$expected" ]] || {
      echo "OpenStatus quiesce: Deployment/$deployment replicas changed since the plan" >&2
      exit 1
    }
  done
  current_workflows_image="$(kubectl -n "$namespace" get pod \
    -l app.kubernetes.io/name=openstatus-workflows \
    -o jsonpath='{.items[0].status.containerStatuses[?(@.name=="workflows")].imageID}')"
  [[ "$current_workflows_image" == "$holder_image" ]] || {
    echo "OpenStatus quiesce: workflows image digest changed since the plan" >&2
    exit 1
  }
  if kubectl -n "$namespace" get pod "$holder_name" >/dev/null 2>&1; then
    echo "OpenStatus quiesce: Pod/$holder_name now exists" >&2
    exit 1
  fi
  trap restore_after_failed_stop EXIT
  kubectl -n "$namespace" patch kustomization.kustomize.toolkit.fluxcd.io openstatus \
    --type=merge -p '{"spec":{"suspend":true}}' >/dev/null
  for deployment in "${writers[@]}"; do
    kubectl -n "$namespace" scale deployment "$deployment" --replicas=0 >/dev/null
  done
  for deployment in "${writers[@]}"; do
    kubectl -n "$namespace" wait --for=jsonpath='{.status.availableReplicas}'=0 \
      deployment/"$deployment" --timeout=120s >/dev/null 2>&1 ||
      kubectl -n "$namespace" wait --for=delete pod -l "app.kubernetes.io/name=$deployment" --timeout=120s >/dev/null
  done
  holder_json="$(jq -n --arg name "$holder_name" --arg namespace "$namespace" \
    --arg run "$state_run_id" --arg image "$holder_image" '
    {
      apiVersion:"v1",kind:"Pod",
      metadata:{name:$name,namespace:$namespace,labels:{
        "app.kubernetes.io/name":"openstatus-backup-holder",
        "openstatus.beaco.works/baseline-run":$run
      }},
      spec:{restartPolicy:"Never",automountServiceAccountToken:false,
        containers:[{name:"holder",image:$image,imagePullPolicy:"IfNotPresent",
          command:["/bin/sh","-c","sleep 900"],
          securityContext:{allowPrivilegeEscalation:false,readOnlyRootFilesystem:true},
          volumeMounts:[{name:"workflows",mountPath:"/app/data",readOnly:true}]}],
        volumes:[{name:"workflows",persistentVolumeClaim:{claimName:"openstatus-workflows-data",readOnly:true}}]
      }
    }')"
  kubectl create -f - <<<"$holder_json" >/dev/null
  kubectl -n "$namespace" wait --for=condition=Ready "pod/$holder_name" --timeout=120s >/dev/null
  trap - EXIT
  echo "OpenStatus quiesce: five writers stopped; read-only workflows holder ready; start the 600-second timer"
  exit 0
fi

delete_holder
resume_complete=false
ensure_flux_resumed() {
  local rc=$?
  trap - EXIT
  if [[ "$resume_complete" != "true" ]]; then
    echo "OpenStatus quiesce: resume incomplete; forcing Flux suspend=false" >&2
    kubectl -n "$namespace" patch kustomization.kustomize.toolkit.fluxcd.io openstatus \
      --type=merge -p '{"spec":{"suspend":false}}' >/dev/null 2>&1 || true
  fi
  exit "$rc"
}
trap ensure_flux_resumed EXIT
for deployment in "${writers[@]}"; do
  replicas="$(jq -r --arg name "$deployment" '.writers[] | select(.name == $name) | .replicas' "$state_file")"
  kubectl -n "$namespace" scale deployment "$deployment" --replicas="$replicas" >/dev/null
done
kubectl -n "$namespace" patch kustomization.kustomize.toolkit.fluxcd.io openstatus \
  --type=merge -p '{"spec":{"suspend":false}}' >/dev/null
kubectl -n "$namespace" wait --for=condition=Ready \
  kustomization.kustomize.toolkit.fluxcd.io/openstatus --timeout=300s >/dev/null
for deployment in "${writers[@]}"; do
  replicas="$(jq -r --arg name "$deployment" '.writers[] | select(.name == $name) | .replicas' "$state_file")"
  if (( replicas > 0 )); then
    kubectl -n "$namespace" rollout status deployment/"$deployment" --timeout=300s >/dev/null
  fi
done
resume_complete=true
trap - EXIT
echo "OpenStatus quiesce: original replicas restored and Flux resumed"
