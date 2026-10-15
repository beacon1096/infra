#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd -- "$script_dir/.." && pwd)"
tmp_dir="$(mktemp -d "$repo_dir/.openstatus-quiesce-test.XXXXXX")"
cleanup() {
  local rc=$?
  if (( rc != 0 )); then
    echo "OpenStatus quiesce fixture failure; captured command logs:" >&2
    find "$tmp_dir" -maxdepth 2 -type f \( -name '*.log' -o -name '*.err' \) \
      -print -exec sed -n '1,240p' {} \; >&2 || true
  fi
  rm -rf -- "$tmp_dir"
  exit "$rc"
}
trap cleanup EXIT

state_file="$tmp_dir/state.json"
jq -n '{
  schema_version:1,run_id:"fixture",namespace:"monitoring",
  flux:{name:"openstatus",revision:"main@fixture",suspend:false},
  writers:[
    {name:"openstatus-server",replicas:1},
    {name:"openstatus-dashboard",replicas:1},
    {name:"openstatus-workflows",replicas:1},
    {name:"openstatus-checker",replicas:1},
    {name:"openstatus-private-location",replicas:0},
    {name:"openstatus-probe-wanxiang",replicas:0}
  ],
  holder:{
    name:"openstatus-backup-holder-fixture",
    image:("example@sha256:"+("0"*64)),
    pvc:"openstatus-workflows-data",read_only:true,max_seconds:900
  },
  maintenance_window_seconds:600
}' >"$state_file"
state_sha="$(sha256sum "$state_file" | awk '{print $1}')"

cat >"$tmp_dir/kubectl" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$MOCK_KUBECTL_LOG"

if [[ "${MOCK_MODE:-}" == "unknown-holder" &&
  "$*" == '-n monitoring get pod openstatus-backup-holder-fixture --ignore-not-found -o json' ]]; then
  printf '%s\n' '{"metadata":{"labels":{"openstatus.beaco.works/baseline-run":"unexpected"}},"spec":{"volumes":[{"name":"workflows","persistentVolumeClaim":{"claimName":"openstatus-workflows-data","readOnly":true}}]}}'
  exit 0
fi
if [[ "${MOCK_MODE:-}" == "stop" ]]; then
  if [[ "$*" == '-n monitoring get kustomization.kustomize.toolkit.fluxcd.io openstatus -o json' ]]; then
    printf '%s\n' '{"spec":{"suspend":false},"status":{"lastAppliedRevision":"main@fixture","conditions":[{"type":"Ready","status":"True"}]}}'
    exit 0
  fi
  if [[ "$*" == '-n monitoring get deployment '*' -o jsonpath={.spec.replicas}' ]]; then
    if [[ "$*" == *'openstatus-private-location'* || "$*" == *'openstatus-probe-wanxiang'* ]]; then
      printf '0'
    else
      printf '1'
    fi
    exit 0
  fi
  if [[ "$*" == '-n monitoring get pod -l app.kubernetes.io/name=openstatus-workflows -o jsonpath={.items[0].status.containerStatuses[?(@.name=="workflows")].imageID}' ]]; then
    printf 'example@sha256:%064d' 0
    exit 0
  fi
  if [[ "$*" == '-n monitoring get pod openstatus-backup-holder-fixture --ignore-not-found -o name' ]]; then
    exit 0
  fi
  if [[ "$*" == '-n monitoring get pod -l app.kubernetes.io/name='*' -o json' ]]; then
    printf '%s\n' '{"items":[]}'
    exit 0
  fi
fi
exit 0
STUB
chmod +x "$tmp_dir/kubectl"
[[ "$(PATH="$tmp_dir:$PATH" command -v kubectl)" == "$tmp_dir/kubectl" ]]

kubectl_log="$tmp_dir/kubectl.log"
: >"$kubectl_log"
MOCK_KUBECTL_LOG="$kubectl_log" bash "$tmp_dir/kubectl" fixture-sanity
grep -q '^fixture-sanity$' "$kubectl_log"
: >"$kubectl_log"
set +e
OPENSTATUS_KUBECTL_BIN="$tmp_dir/kubectl" MOCK_MODE=unknown-holder MOCK_KUBECTL_LOG="$kubectl_log" \
REPLICA_STATE_FILE="$state_file" EXPECTED_REPLICA_STATE_SHA256="$state_sha" \
OPENSTATUS_RECOVERY_MAX_SECONDS=30 \
  bash "$script_dir/quiesce-openstatus-writers.sh" --resume >/dev/null 2>"$tmp_dir/holder.err"
holder_rc=$?
set -e
[[ "$holder_rc" == "1" ]]
grep -q 'scale deployment openstatus-dashboard --replicas=1' "$kubectl_log"
grep -q 'patch kustomization.kustomize.toolkit.fluxcd.io openstatus.*suspend.*false' "$kubectl_log"
! grep -q 'delete pod openstatus-backup-holder-fixture' "$kubectl_log"

: >"$kubectl_log"
OPENSTATUS_KUBECTL_BIN="$tmp_dir/kubectl" MOCK_MODE=stop MOCK_KUBECTL_LOG="$kubectl_log" \
REPLICA_STATE_FILE="$state_file" EXPECTED_REPLICA_STATE_SHA256="$state_sha" \
QUIESCE_DEADLINE_EPOCH="$(( $(date -u +%s) + 30 ))" \
  bash "$script_dir/quiesce-openstatus-writers.sh" --stop >/dev/null
grep -q 'scale deployment openstatus-dashboard --replicas=0' "$kubectl_log"
grep -q 'get pod -l app.kubernetes.io/name=openstatus-dashboard -o json' "$kubectl_log"

wrapper_dir="$tmp_dir/wrapper"
mkdir -p "$wrapper_dir"
cp "$script_dir/with-openstatus-quiesced.sh" "$wrapper_dir/with-openstatus-quiesced.sh"
cat >"$wrapper_dir/quiesce-openstatus-writers.sh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$1" >>"$MOCK_WINDOW_LOG"
if [[ "$1" == "--stop" && "${FAIL_STOP:-0}" == "1" ]]; then
  exit 37
fi
STUB
chmod +x "$wrapper_dir/quiesce-openstatus-writers.sh"

run_failure_case() {
  local name="$1"
  local expected_rc="$2"
  shift 2
  local log="$tmp_dir/${name}.log"
  local rc
  : >"$log"
  set +e
  MOCK_WINDOW_LOG="$log" REPLICA_STATE_FILE="$state_file" \
  EXPECTED_REPLICA_STATE_SHA256="$state_sha" \
  OPENSTATUS_MAINTENANCE_WINDOW_SECONDS=2 \
    bash "$wrapper_dir/with-openstatus-quiesced.sh" -- "$@" >/dev/null 2>&1
  rc=$?
  set -e
  [[ "$rc" == "$expected_rc" ]]
  [[ "$(grep -c '^--stop$' "$log")" == "1" ]]
  [[ "$(grep -c '^--resume$' "$log")" == "1" ]]
}

run_failure_case baseline-failure 41 bash -c 'exit 41'
run_failure_case job-create-failure 42 bash -c 'exit 42'
run_failure_case deadline-timeout 124 sleep 3
run_failure_case interrupt 143 bash -c 'kill -TERM "$OPENSTATUS_WINDOW_PID"; exit 0'

stop_log="$tmp_dir/stop-failure.log"
: >"$stop_log"
set +e
MOCK_WINDOW_LOG="$stop_log" FAIL_STOP=1 REPLICA_STATE_FILE="$state_file" \
EXPECTED_REPLICA_STATE_SHA256="$state_sha" OPENSTATUS_MAINTENANCE_WINDOW_SECONDS=2 \
  bash "$wrapper_dir/with-openstatus-quiesced.sh" -- true >/dev/null 2>&1
stop_rc=$?
set -e
[[ "$stop_rc" == "37" ]]
[[ "$(grep -c '^--resume$' "$stop_log")" == "1" ]]

runtime_manifest="$repo_dir/wanxiang/kubernetes/apps/monitoring/openstatus/app/tinybird.yaml"
runtime_patch="$repo_dir/wanxiang/kubernetes/apps/monitoring/openstatus/app/tinybird-runtime-pin.patch.json"
runtime_kustomization="$repo_dir/wanxiang/kubernetes/apps/monitoring/openstatus/app/kustomization.yaml"
! grep -q 'tinybird-local:latest@sha256:' "$runtime_manifest"
! grep -q 'tinybird-runtime-pin.patch.json' "$runtime_kustomization"
jq -e '
  length == 1 and .[0].op == "replace" and
  .[0].path == "/spec/template/spec/containers/0/image" and
  (.[0].value | endswith("@sha256:107829e9143df641e81c7339b0fd7bf9ed97bcea8841f1bb7e9b2fc966049b20"))
' "$runtime_patch" >/dev/null

echo "OpenStatus quiesce fixtures: dashboard exit, bounded recovery, holder refusal and runtime gate passed"
