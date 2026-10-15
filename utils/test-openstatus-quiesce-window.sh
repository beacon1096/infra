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

if [[ "$*" == '-n monitoring get kustomization.kustomize.toolkit.fluxcd.io openstatus -o json' ]]; then
  printf '{"spec":{"suspend":%s},"status":{"lastAppliedRevision":"%s","conditions":[{"type":"Ready","status":"True"}]}}\n' \
    "$(<"$MOCK_STATE_DIR/flux-suspend")" "$(<"$MOCK_STATE_DIR/flux-revision")"
  exit 0
fi
if [[ "$*" == '-n monitoring get pod -l app.kubernetes.io/name=openstatus-workflows -o jsonpath={.items[0].status.containerStatuses[?(@.name=="workflows")].imageID}' ]]; then
  printf 'example@sha256:%064d' 0
  exit 0
fi
for deployment in openstatus-server openstatus-dashboard openstatus-workflows openstatus-checker openstatus-private-location openstatus-probe-wanxiang; do
  if [[ "$*" == "-n monitoring get deployment $deployment -o jsonpath={.spec.replicas}" ]]; then
    cat "$MOCK_STATE_DIR/replica-$deployment"
    exit 0
  fi
  if [[ "$*" == "-n monitoring get pod -l app.kubernetes.io/name=$deployment -o json" ]]; then
    if [[ "$(<"$MOCK_STATE_DIR/replica-$deployment")" == "0" ]]; then
      printf '%s\n' '{"items":[]}'
    else
      printf '%s\n' '{"items":[{}]}'
    fi
    exit 0
  fi
done
if [[ "$*" == '-n monitoring get pod openstatus-backup-holder-fixture --ignore-not-found -o name' ]]; then
  [[ "$(<"$MOCK_STATE_DIR/holder")" == "none" ]] || printf '%s\n' 'pod/openstatus-backup-holder-fixture'
  exit 0
fi
if [[ "$*" == '-n monitoring get pod openstatus-backup-holder-fixture --ignore-not-found -o json' ]]; then
  holder="$(<"$MOCK_STATE_DIR/holder")"
  if [[ "$holder" == "expected" ]]; then
    printf '%s\n' '{"metadata":{"labels":{"openstatus.beaco.works/baseline-run":"fixture"}},"spec":{"volumes":[{"name":"workflows","persistentVolumeClaim":{"claimName":"openstatus-workflows-data","readOnly":true}}]}}'
  elif [[ "$holder" == "foreign" ]]; then
    printf '%s\n' '{"metadata":{"labels":{"openstatus.beaco.works/baseline-run":"somebody-else"}},"spec":{"volumes":[]}}'
  fi
  exit 0
fi
if [[ "$*" == *' patch kustomization.kustomize.toolkit.fluxcd.io openstatus '* ]]; then
  if [[ "$*" == *'"suspend":true'* ]]; then
    printf '%s\n' true >"$MOCK_STATE_DIR/flux-suspend"
    if [[ "$MOCK_MODE" == "first-mutation-failure" && ! -e "$MOCK_STATE_DIR/failed-once" ]]; then
      : >"$MOCK_STATE_DIR/failed-once"
      exit 37
    fi
  else
    printf '%s\n' false >"$MOCK_STATE_DIR/flux-suspend"
  fi
  exit 0
fi
if [[ "${3:-}" == "scale" && "${4:-}" == "deployment" ]]; then
  deployment="$5"
  replicas="${6#--replicas=}"
  printf '%s\n' "$replicas" >"$MOCK_STATE_DIR/replica-$deployment"
  if [[ "$MOCK_MODE" == "later-mutation-failure" && "$deployment" == "openstatus-dashboard" &&
    "$replicas" == "0" && ! -e "$MOCK_STATE_DIR/failed-once" ]]; then
    : >"$MOCK_STATE_DIR/failed-once"
    exit 38
  fi
  exit 0
fi
if [[ "$*" == 'create -f -' ]]; then
  cat >/dev/null
  printf '%s\n' expected >"$MOCK_STATE_DIR/holder"
  exit 0
fi
if [[ "$*" == '-n monitoring delete pod openstatus-backup-holder-fixture --wait=true' ]]; then
  printf '%s\n' none >"$MOCK_STATE_DIR/holder"
  exit 0
fi
exit 0
STUB
chmod +x "$tmp_dir/kubectl"
[[ "$(PATH="$tmp_dir:$PATH" command -v kubectl)" == "$tmp_dir/kubectl" ]]

initialize_case() {
  local name="$1"
  local mode="$2"
  case_dir="$tmp_dir/$name"
  mkdir -p "$case_dir"
  kubectl_log="$case_dir/kubectl.log"
  payload_log="$case_dir/payload.log"
  : >"$kubectl_log"
  : >"$payload_log"
  printf '%s\n' false >"$case_dir/flux-suspend"
  printf '%s\n' 'main@fixture' >"$case_dir/flux-revision"
  printf '%s\n' none >"$case_dir/holder"
  for deployment in openstatus-server openstatus-dashboard openstatus-workflows openstatus-checker; do
    printf '%s\n' 1 >"$case_dir/replica-$deployment"
  done
  for deployment in openstatus-private-location openstatus-probe-wanxiang; do
    printf '%s\n' 0 >"$case_dir/replica-$deployment"
  done
  case "$mode" in
    flux-drift)
      printf '%s\n' true >"$case_dir/flux-suspend"
      printf '%s\n' 'main@changed' >"$case_dir/flux-revision"
      ;;
    replica-drift) printf '%s\n' 2 >"$case_dir/replica-openstatus-dashboard" ;;
    existing-holder) printf '%s\n' foreign >"$case_dir/holder" ;;
  esac
}

run_case() {
  local name="$1" mode="$2" expected_rc="$3"
  shift 3
  initialize_case "$name" "$mode"
  set +e
  OPENSTATUS_KUBECTL_BIN="$tmp_dir/kubectl" MOCK_MODE="$mode" \
  MOCK_STATE_DIR="$case_dir" MOCK_KUBECTL_LOG="$kubectl_log" PAYLOAD_LOG="$payload_log" \
  REPLICA_STATE_FILE="$state_file" EXPECTED_REPLICA_STATE_SHA256="$state_sha" \
  OPENSTATUS_QUIESCE_OWNERSHIP_FILE="$case_dir/ownership.json" \
  OPENSTATUS_RECOVERY_MAX_SECONDS=30 \
  OPENSTATUS_MAINTENANCE_WINDOW_SECONDS=2 \
    bash "$script_dir/with-openstatus-quiesced.sh" -- "$@" >"$case_dir/out.log" 2>"$case_dir/err.log"
  case_rc=$?
  set -e
  [[ "$case_rc" == "$expected_rc" ]]
}

assert_zero_mutations() {
  ! grep -Eq '(^| )(patch|scale|create|delete)( |$)' "$kubectl_log"
  [[ ! -e "$case_dir/ownership.json" ]]
  [[ ! -s "$payload_log" ]]
}

assert_recovered() {
  jq -e --arg sha "$state_sha" \
    '.schema_version == 1 and .state_sha256 == $sha and .phase == "recovered"' \
    "$case_dir/ownership.json" >/dev/null
  [[ "$(<"$case_dir/flux-suspend")" == "false" ]]
  [[ "$(<"$case_dir/holder")" == "none" ]]
  [[ "$(<"$case_dir/replica-openstatus-dashboard")" == "1" ]]
  grep -q 'patch kustomization.kustomize.toolkit.fluxcd.io openstatus.*suspend.*false' "$kubectl_log"
  [[ "$(grep -c 'patch kustomization.kustomize.toolkit.fluxcd.io openstatus.*suspend.*false' "$kubectl_log")" == "1" ]]
  [[ "$(grep -c 'scale deployment openstatus-dashboard --replicas=1' "$kubectl_log")" == "1" ]]
}

run_case flux-preflight flux-drift 1 bash -c 'echo payload >>"$PAYLOAD_LOG"'
assert_zero_mutations
run_case replica-preflight replica-drift 1 bash -c 'echo payload >>"$PAYLOAD_LOG"'
assert_zero_mutations
run_case holder-preflight existing-holder 1 bash -c 'echo payload >>"$PAYLOAD_LOG"'
assert_zero_mutations

run_case first-mutation first-mutation-failure 37 bash -c 'echo payload >>"$PAYLOAD_LOG"'
assert_recovered
[[ ! -s "$payload_log" ]]
grep -q 'suspend.*true' "$kubectl_log"

run_case later-mutation later-mutation-failure 38 bash -c 'echo payload >>"$PAYLOAD_LOG"'
assert_recovered
[[ ! -s "$payload_log" ]]
grep -q 'scale deployment openstatus-dashboard --replicas=0' "$kubectl_log"

run_case payload-failure normal 41 bash -c 'exit 41'
assert_recovered
run_case deadline-timeout normal 124 sleep 3
assert_recovered
run_case interrupt normal 143 bash -c 'kill -TERM "$OPENSTATUS_WINDOW_PID"; sleep 1'
assert_recovered
run_case success normal 0 bash -c 'echo payload >>"$PAYLOAD_LOG"'
assert_recovered
grep -q '^payload$' "$payload_log"

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

echo "OpenStatus quiesce fixtures: real wrapper/helper preflight ownership, mutation failure, signal/timeout recovery and runtime gate passed"
