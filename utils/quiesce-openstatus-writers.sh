#!/usr/bin/env bash
set -euo pipefail

mode="${1:---plan}"
namespace="${OPENSTATUS_NAMESPACE:-monitoring}"
run_id="${RUN_ID:-}"
state_file="${REPLICA_STATE_FILE:-}"
expected_sha256="${EXPECTED_REPLICA_STATE_SHA256:-}"
writers=(
  openstatus-server
  openstatus-dashboard
  openstatus-workflows
  openstatus-checker
  openstatus-private-location
  openstatus-probe-wanxiang
)
legacy_writers=(
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
for command in jq sha256sum timeout date head; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "OpenStatus quiesce: $command is required" >&2
    exit 2
  }
done
kubectl_path="${OPENSTATUS_KUBECTL_BIN:-$(command -v kubectl || true)}"
[[ -n "$kubectl_path" && -r "$kubectl_path" ]] || {
  echo "OpenStatus quiesce: kubectl is required" >&2
  exit 2
}
kubectl_command=("$kubectl_path")
# CI fixtures live on a noexec workspace. Invoke shell stubs through bash so a
# failed test can never fall through PATH to a real cluster client.
if [[ "$(head -c 2 -- "$kubectl_path")" == '#!' ]]; then
  kubectl_command=(bash "$kubectl_path")
fi

bounded() {
  local deadline="$1"
  local maximum="$2"
  shift 2
  local now remaining seconds
  now="$(date -u +%s)"
  remaining=$((deadline - now))
  if (( remaining <= 0 )); then
    echo "OpenStatus quiesce: operation deadline expired" >&2
    return 124
  fi
  seconds="$remaining"
  (( seconds > maximum )) && seconds="$maximum"
  timeout --foreground --kill-after=5s "${seconds}s" "$@"
}

read_only() {
  local deadline
  deadline=$(( $(date -u +%s) + 30 ))
  bounded "$deadline" 30 "$@"
}

if [[ "$mode" == "--plan" ]]; then
  [[ "$run_id" =~ ^[a-z0-9]([a-z0-9-]{0,18}[a-z0-9])?$ ]] || {
    echo "OpenStatus quiesce: RUN_ID must be 1-20 lowercase alphanumeric/hyphen characters" >&2
    exit 2
  }
  flux_json="$(read_only "${kubectl_command[@]}" -n "$namespace" get kustomization.kustomize.toolkit.fluxcd.io openstatus -o json)"
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
    deployment_json="$(read_only "${kubectl_command[@]}" -n "$namespace" get deployment "$deployment" -o json)" || {
      echo "OpenStatus quiesce: Deployment/$deployment is missing" >&2
      exit 1
    }
    jq -e --arg name "$deployment" '
      .metadata.name == $name and
      .spec.selector.matchLabels["app.kubernetes.io/name"] == $name and
      .spec.template.metadata.labels["app.kubernetes.io/name"] == $name
    ' <<<"$deployment_json" >/dev/null || {
      echo "OpenStatus quiesce: Deployment/$deployment does not have the expected pod selector" >&2
      exit 1
    }
    replicas="$(jq -c --arg name "$deployment" --argjson replicas "$(jq -r '.spec.replicas // 1' <<<"$deployment_json")" \
      '. + [{name:$name,replicas:$replicas}]' <<<"$replicas")"
  done
  workflows_pods="$(read_only "${kubectl_command[@]}" -n "$namespace" get pod \
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
  existing_holder="$(read_only "${kubectl_command[@]}" -n "$namespace" get pod "$holder_name" --ignore-not-found -o name)"
  [[ -z "$existing_holder" ]] || {
    echo "OpenStatus quiesce: Pod/$holder_name already exists" >&2
    exit 1
  }
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
current_names="$(printf '%s\n' "${writers[@]}" | jq -R . | jq -s -c .)"
legacy_names="$(printf '%s\n' "${legacy_writers[@]}" | jq -R . | jq -s -c .)"
jq -e --arg namespace "$namespace" '
  .schema_version == 1 and .namespace == $namespace and
  (.run_id | test("^[a-z0-9]([a-z0-9-]{0,18}[a-z0-9])?$")) and
  .flux.name == "openstatus" and .flux.suspend == false and
  .maintenance_window_seconds == 600 and
  all(.writers[]; (.replicas | type == "number") and .replicas >= 0) and
  .holder.name == ("openstatus-backup-holder-" + .run_id) and
  (.holder.image | test("@sha256:[0-9a-f]{64}$")) and
  .holder.pvc == "openstatus-workflows-data" and .holder.read_only == true and
  .holder.max_seconds == 900
' "$state_file" >/dev/null || {
  echo "OpenStatus quiesce: replica state file is invalid or incomplete" >&2
  exit 1
}
state_names="$(jq -c '[.writers[].name]' "$state_file")"
if [[ "$mode" == "--stop" ]]; then
  [[ "$state_names" == "$current_names" ]] || {
    echo "OpenStatus quiesce: stop requires a new plan containing all six writers" >&2
    exit 1
  }
elif [[ "$state_names" != "$current_names" && "$state_names" != "$legacy_names" ]]; then
  echo "OpenStatus quiesce: resume state contains an unexpected writer set" >&2
  exit 1
fi

holder_name="$(jq -r '.holder.name' "$state_file")"
holder_image="$(jq -r '.holder.image' "$state_file")"
state_run_id="$(jq -r '.run_id' "$state_file")"
mapfile -t state_writers < <(jq -r '.writers[].name' "$state_file")

delete_holder() {
  local deadline="$1"
  local holder_json
  holder_json="$(bounded "$deadline" 30 "${kubectl_command[@]}" -n "$namespace" get pod "$holder_name" --ignore-not-found -o json)" || {
    echo "OpenStatus quiesce: could not inspect Pod/$holder_name; preserving it" >&2
    return 1
  }
  [[ -n "$holder_json" ]] || return 0
  jq -e --arg run "$state_run_id" '
    .metadata.labels["openstatus.beaco.works/baseline-run"] == $run and
    .spec.volumes == [{name:"workflows",persistentVolumeClaim:{claimName:"openstatus-workflows-data",readOnly:true}}]
  ' <<<"$holder_json" >/dev/null || {
    echo "OpenStatus quiesce: refusing to delete unexpected Pod/$holder_name" >&2
    return 1
  }
  bounded "$deadline" 60 "${kubectl_command[@]}" -n "$namespace" delete pod "$holder_name" --wait=true >/dev/null
}

restore_recorded_state() {
  local recovery_seconds="${OPENSTATUS_RECOVERY_MAX_SECONDS:-300}"
  [[ "$recovery_seconds" =~ ^[0-9]+$ ]] && (( recovery_seconds >= 30 && recovery_seconds <= 600 )) || {
    echo "OpenStatus quiesce: OPENSTATUS_RECOVERY_MAX_SECONDS must be 30-600" >&2
    return 2
  }
  local deadline rc deployment replicas wait_seconds
  deadline=$(( $(date -u +%s) + recovery_seconds ))
  rc=0

  # A foreign or malformed holder is deliberately preserved, but it must not
  # prevent replica restoration or Flux resume.
  delete_holder "$deadline" || rc=1
  for deployment in "${state_writers[@]}"; do
    replicas="$(jq -r --arg name "$deployment" '.writers[] | select(.name == $name) | .replicas' "$state_file")"
    bounded "$deadline" 30 "${kubectl_command[@]}" -n "$namespace" scale deployment "$deployment" \
      --replicas="$replicas" >/dev/null || rc=1
  done
  bounded "$deadline" 30 "${kubectl_command[@]}" -n "$namespace" patch \
    kustomization.kustomize.toolkit.fluxcd.io openstatus \
    --type=merge -p '{"spec":{"suspend":false}}' >/dev/null || rc=1

  wait_seconds=$((deadline - $(date -u +%s)))
  if (( wait_seconds > 0 )); then
    bounded "$deadline" "$wait_seconds" "${kubectl_command[@]}" -n "$namespace" wait --for=condition=Ready \
      kustomization.kustomize.toolkit.fluxcd.io/openstatus \
      --timeout="${wait_seconds}s" >/dev/null || rc=1
  else
    rc=1
  fi
  for deployment in "${state_writers[@]}"; do
    replicas="$(jq -r --arg name "$deployment" '.writers[] | select(.name == $name) | .replicas' "$state_file")"
    if (( replicas > 0 )); then
      wait_seconds=$((deadline - $(date -u +%s)))
      if (( wait_seconds <= 0 )); then
        rc=1
        continue
      fi
      bounded "$deadline" "$wait_seconds" "${kubectl_command[@]}" -n "$namespace" rollout status \
        deployment/"$deployment" --timeout="${wait_seconds}s" >/dev/null || rc=1
    fi
  done
  return "$rc"
}

if [[ "$mode" == "--stop" ]]; then
  window_deadline="${QUIESCE_DEADLINE_EPOCH:-}"
  now="$(date -u +%s)"
  [[ "$window_deadline" =~ ^[0-9]+$ ]] &&
    (( window_deadline > now && window_deadline <= now + 600 )) || {
    echo "OpenStatus quiesce: QUIESCE_DEADLINE_EPOCH must be set before stop and be at most 600 seconds away" >&2
    exit 2
  }
  flux_json="$(bounded "$window_deadline" 30 "${kubectl_command[@]}" -n "$namespace" get \
    kustomization.kustomize.toolkit.fluxcd.io openstatus -o json)"
  jq -e --arg revision "$(jq -r '.flux.revision' "$state_file")" '
    (.spec.suspend // false) == false and .status.lastAppliedRevision == $revision and
    any(.status.conditions[]?; .type == "Ready" and .status == "True")
  ' <<<"$flux_json" >/dev/null || {
    echo "OpenStatus quiesce: Flux state or revision changed since the plan" >&2
    exit 1
  }
  for deployment in "${writers[@]}"; do
    current="$(bounded "$window_deadline" 30 "${kubectl_command[@]}" -n "$namespace" get deployment \
      "$deployment" -o jsonpath='{.spec.replicas}')"
    expected="$(jq -r --arg name "$deployment" '.writers[] | select(.name == $name) | .replicas' "$state_file")"
    [[ "$current" == "$expected" ]] || {
      echo "OpenStatus quiesce: Deployment/$deployment replicas changed since the plan" >&2
      exit 1
    }
  done
  current_workflows_image="$(bounded "$window_deadline" 30 "${kubectl_command[@]}" -n "$namespace" get pod \
    -l app.kubernetes.io/name=openstatus-workflows \
    -o jsonpath='{.items[0].status.containerStatuses[?(@.name=="workflows")].imageID}')"
  [[ "$current_workflows_image" == "$holder_image" ]] || {
    echo "OpenStatus quiesce: workflows image digest changed since the plan" >&2
    exit 1
  }
  existing_holder="$(bounded "$window_deadline" 30 "${kubectl_command[@]}" -n "$namespace" get pod \
    "$holder_name" --ignore-not-found -o name)"
  [[ -z "$existing_holder" ]] || {
    echo "OpenStatus quiesce: Pod/$holder_name now exists" >&2
    exit 1
  }

  stop_needs_restore=true
  restore_after_failed_stop() {
    local rc=$?
    trap - EXIT INT TERM
    if [[ "$stop_needs_restore" == "true" ]]; then
      echo "OpenStatus quiesce: stop failed or was interrupted; restoring recorded state" >&2
      restore_recorded_state || true
    fi
    exit "$rc"
  }
  trap restore_after_failed_stop EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  bounded "$window_deadline" 30 "${kubectl_command[@]}" -n "$namespace" patch \
    kustomization.kustomize.toolkit.fluxcd.io openstatus \
    --type=merge -p '{"spec":{"suspend":true}}' >/dev/null
  for deployment in "${writers[@]}"; do
    bounded "$window_deadline" 30 "${kubectl_command[@]}" -n "$namespace" scale deployment "$deployment" \
      --replicas=0 >/dev/null
  done

  while true; do
    all_gone=true
    for deployment in "${writers[@]}"; do
      pods_json="$(bounded "$window_deadline" 15 "${kubectl_command[@]}" -n "$namespace" get pod \
        -l "app.kubernetes.io/name=$deployment" -o json)"
      if ! jq -e '.items | length == 0' <<<"$pods_json" >/dev/null; then
        all_gone=false
      fi
    done
    [[ "$all_gone" == "true" ]] && break
    bounded "$window_deadline" 2 sleep 1
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
  bounded "$window_deadline" 30 "${kubectl_command[@]}" create -f - <<<"$holder_json" >/dev/null
  wait_seconds=$((window_deadline - $(date -u +%s)))
  bounded "$window_deadline" "$wait_seconds" "${kubectl_command[@]}" -n "$namespace" wait \
    --for=condition=Ready "pod/$holder_name" --timeout="${wait_seconds}s" >/dev/null
  stop_needs_restore=false
  trap - EXIT INT TERM
  echo "OpenStatus quiesce: six writers stopped and all writer Pods exited; read-only workflows holder ready"
  exit 0
fi

resume_finished=false
restore_on_resume_exit() {
  local rc=$?
  trap - EXIT INT TERM
  if [[ "$resume_finished" != "true" ]]; then
    echo "OpenStatus quiesce: resume interrupted; retrying replica and Flux restoration" >&2
    restore_recorded_state || true
  fi
  exit "$rc"
}
trap restore_on_resume_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
set +e
restore_recorded_state
restore_rc=$?
set -e
resume_finished=true
trap - EXIT INT TERM
if (( restore_rc != 0 )); then
  echo "OpenStatus quiesce: restoration was attempted for every writer and Flux, but one or more checks failed" >&2
  exit "$restore_rc"
fi
echo "OpenStatus quiesce: original replicas restored and Flux resumed"
