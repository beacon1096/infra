#!/usr/bin/env bash
set -euo pipefail

mode="${1:---plan}"
openstatus_namespace="${OPENSTATUS_NAMESPACE:-monitoring}"
upstream_revision="ef7691ad18971c14b9bd1a306b4bd0cf20b6e411"
runtime_digest="sha256:107829e9143df641e81c7339b0fd7bf9ed97bcea8841f1bb7e9b2fc966049b20"
datasource_sha256="ebee697a5b25d3808d2e931d3b0ef77ef2d666e273931099ecabffcf96e96207"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd -- "$script_dir/.." && pwd)"
datasource_file="$repo_dir/wanxiang/kubernetes/apps/monitoring/openstatus/bootstrap/tinybird/ping_response__v8.datasource"
runtime_patch_file="$repo_dir/wanxiang/kubernetes/apps/monitoring/openstatus/app/tinybird-runtime-pin.patch.json"

usage() {
  cat >&2 <<'EOF'
Usage:
  bash utils/initialize-openstatus-tinybird.sh --plan
  TINYBIRD_READ_TOKEN=... bash utils/initialize-openstatus-tinybird.sh --check
  TINYBIRD_CREATE_TOKEN=... TINYBIRD_READ_TOKEN=... \
    CONFIRM_TINYBIRD_INITIALIZE=ping_response__v8@ef7691ad \
    bash utils/initialize-openstatus-tinybird.sh --execute

--plan is read-only. --execute creates only ping_response__v8 and refuses an
already populated datasource. It never creates or updates Kubernetes Secrets.
EOF
}

case "$mode" in
  --plan | --check | --execute) ;;
  -h | --help) usage; exit 0 ;;
  *) usage; exit 2 ;;
esac

for command in kubectl jq curl sha256sum awk sed; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "tinybird initialization: $command is required" >&2
    exit 2
  }
done

actual_sha256="$(sha256sum "$datasource_file" | awk '{print $1}')"
[[ "$actual_sha256" == "$datasource_sha256" ]] || {
  echo "tinybird initialization: pinned datasource checksum mismatch" >&2
  exit 1
}
runtime_patch_image="$(jq -er '
  if length == 1 and .[0].op == "replace" and
    .[0].path == "/spec/template/spec/containers/0/image"
  then .[0].value else error("unexpected runtime patch") end
' "$runtime_patch_file")" || {
  echo "tinybird initialization: staged runtime pin patch is invalid" >&2
  exit 1
}
[[ "$runtime_patch_image" == *@"$runtime_digest" ]] || {
  echo "tinybird initialization: staged runtime pin patch has the wrong digest" >&2
  exit 1
}
runtime_patch_sha256="$(sha256sum "$runtime_patch_file" | awk '{print $1}')"

deployment_image="$(kubectl -n "$openstatus_namespace" get deployment openstatus-tinybird \
  -o jsonpath='{.spec.template.spec.containers[?(@.name=="tinybird")].image}')"
pod_image_id="$(kubectl -n "$openstatus_namespace" get pod \
  -l app.kubernetes.io/name=openstatus-tinybird \
  -o jsonpath='{.items[0].status.containerStatuses[?(@.name=="tinybird")].imageID}')"

if [[ "$mode" == "--plan" ]]; then
  jq -n \
    --arg revision "$upstream_revision" \
    --arg datasource "ping_response__v8" \
    --arg datasource_sha256 "$datasource_sha256" \
    --arg runtime_image "$deployment_image" \
    --arg running_image_id "$pod_image_id" \
    --arg required_digest "$runtime_digest" \
    --arg runtime_patch "wanxiang/kubernetes/apps/monitoring/openstatus/app/tinybird-runtime-pin.patch.json" \
    --arg runtime_patch_sha256 "$runtime_patch_sha256" \
    --arg runtime_patch_image "$runtime_patch_image" '
    {
      operation: "initialize-openstatus-tinybird",
      mutation: "create ping_response__v8 only when absent",
      upstream_revision: $revision,
      datasource: $datasource,
      datasource_sha256: $datasource_sha256,
      runtime: {
        deployment_image: $runtime_image,
        running_image_id: $running_image_id,
        required_digest: $required_digest,
        deployment_pinned: ($runtime_image | endswith("@" + $required_digest)),
        running_digest_matches: ($running_image_id | endswith("@" + $required_digest))
      },
      staged_gitops_patch: {
        path: $runtime_patch,
        sha256: $runtime_patch_sha256,
        image: $runtime_patch_image,
        active_in_kustomization: false,
        gate: "add only in the approved runtime commit after the pre-initialization backup"
      },
      credentials: {
        create: "ephemeral token with DATASOURCES:CREATE only",
        verify: "separate token with DATASOURCES:READ:ping_response__v8 only"
      },
      refusal_states: ["authentication-failed", "ingested", "query-failed"],
      confirmation: "ping_response__v8@ef7691ad"
    }'
  exit 0
fi

[[ "$pod_image_id" == *@"$runtime_digest" ]] || {
  echo "tinybird initialization: running pod is not the validated digest $runtime_digest" >&2
  exit 1
}

[[ -n "${TINYBIRD_READ_TOKEN:-}" ]] || {
  echo "tinybird initialization: TINYBIRD_READ_TOKEN is required" >&2
  exit 2
}

tmp_dir="$(mktemp -d)"
umask 077
printf 'Authorization: Bearer %s\n' "$TINYBIRD_READ_TOKEN" >"$tmp_dir/read-header"
port_forward_pid=""
cleanup() {
  if [[ -n "$port_forward_pid" ]]; then
    kill "$port_forward_pid" 2>/dev/null || true
    wait "$port_forward_pid" 2>/dev/null || true
  fi
  rm -rf -- "$tmp_dir"
}
trap cleanup EXIT

kubectl -n "$openstatus_namespace" port-forward service/openstatus-tinybird 17183:7181 \
  >"$tmp_dir/port-forward.log" 2>&1 &
port_forward_pid=$!
for attempt in 1 2 3 4 5 6 7 8 9 10; do
  curl -fsS http://127.0.0.1:17183/ >/dev/null 2>&1 && break
  if [[ "$attempt" == 10 ]]; then
    echo "tinybird initialization: port-forward did not become ready" >&2
    exit 1
  fi
  sleep 1
done

query='SELECT count() AS result_count, uniqExact(cronTimestamp) AS distinct_intervals, uniqExact(monitorId) AS monitors, uniqExact(region) AS regions FROM ping_response__v8'
query_state() {
  local http_code state rc
  http_code="$(curl -sS -G http://127.0.0.1:17183/v0/sql \
    -H "@$tmp_dir/read-header" --data-urlencode "q=$query" \
    -o "$tmp_dir/query-response.json" -w '%{http_code}')"
  set +e
  state="$(bash "$script_dir/classify-openstatus-tinybird-query.sh" \
    "$http_code" "$tmp_dir/query-response.json")"
  rc=$?
  set -e
  printf '%s\t%s\n' "$state" "$rc"
}

IFS=$'\t' read -r state state_rc < <(query_state)
if [[ "$mode" == "--check" ]]; then
  printf '%s\n' "$state"
  exit "$state_rc"
fi

[[ "${CONFIRM_TINYBIRD_INITIALIZE:-}" == "ping_response__v8@ef7691ad" ]] || {
  echo "tinybird initialization: exact confirmation is required" >&2
  exit 2
}
[[ "$deployment_image" == *@"$runtime_digest" ]] || {
  echo "tinybird initialization: Deployment is not declaratively pinned to $runtime_digest" >&2
  exit 1
}
[[ -n "${TINYBIRD_CREATE_TOKEN:-}" ]] || {
  echo "tinybird initialization: TINYBIRD_CREATE_TOKEN is required" >&2
  exit 2
}
case "$state" in
  initialized-empty)
    echo "tinybird initialization: already initialized-empty; no mutation"
    exit 0
    ;;
  uninitialized) ;;
  authentication-failed)
    echo "tinybird initialization: read authentication failed; no mutation" >&2
    exit 1
    ;;
  ingested)
    echo "tinybird initialization: datasource already contains data; no mutation" >&2
    exit 1
    ;;
  *)
    echo "tinybird initialization: preflight query failed; no mutation" >&2
    exit 1
    ;;
esac

schema="$(awk '
  /^SCHEMA >/ { in_schema=1; next }
  /^ENGINE / { in_schema=0 }
  in_schema { print }
' "$datasource_file" | sed '/^[[:space:]]*$/d')"
printf 'Authorization: Bearer %s\n' "$TINYBIRD_CREATE_TOKEN" >"$tmp_dir/create-header"
create_code="$(curl -sS -X POST http://127.0.0.1:17183/v0/datasources \
  -H "@$tmp_dir/create-header" \
  --data-urlencode 'name=ping_response__v8' \
  --data-urlencode "schema=$schema" \
  --data-urlencode 'engine=MergeTree' \
  --data-urlencode 'engine_partition_key=toYYYYMM(fromUnixTimestamp64Milli(cronTimestamp))' \
  --data-urlencode 'engine_sorting_key=monitorId, cronTimestamp' \
  -o "$tmp_dir/create-response.json" -w '%{http_code}')"
[[ "$create_code" == "200" || "$create_code" == "201" ]] || {
  echo "tinybird initialization: create failed with HTTP $create_code" >&2
  exit 1
}

for attempt in 1 2 3 4 5 6 7 8 9 10; do
  IFS=$'\t' read -r state state_rc < <(query_state)
  [[ "$state" == "initialized-empty" && "$state_rc" == "0" ]] && {
    echo "tinybird initialization: initialized-empty verified"
    exit 0
  }
  sleep 1
done
echo "tinybird initialization: create returned success but empty datasource verification failed" >&2
exit 1
