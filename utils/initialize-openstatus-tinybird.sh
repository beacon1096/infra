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
# shellcheck source=utils/openstatus-tinybird-auth.sh
source "$script_dir/openstatus-tinybird-auth.sh"

usage() {
  cat >&2 <<'EOF'
Usage:
  bash utils/initialize-openstatus-tinybird.sh --plan
  TINYBIRD_ADMIN_TOKEN_FILE=... bash utils/initialize-openstatus-tinybird.sh --check
  TINYBIRD_ADMIN_TOKEN_FILE=... TINYBIRD_CREATE_TOKEN_FILE=... \
    CONFIRM_TINYBIRD_INITIALIZE=ping_response__v8@ef7691ad \
    bash utils/initialize-openstatus-tinybird.sh --execute

--plan is read-only and does not require a credential. --check lists
datasources with the management identity and does not need a
DATASOURCES:READ:ping_response__v8 token. That scoped token cannot be issued
while the datasource is absent. When the list shows the target and a separate
read credential is present, --check then distinguishes empty from ingested.
401/403 is authentication failure. Other HTTP, transport, JSON, and identity
failures are not treated as an absent datasource.

--execute refuses before the first mutation unless both the management
identity and the create credential are usable. The application key
TINY_BIRD_API_KEY is not a management identity. Supply either the environment
variable or the *_FILE path, not both. This command does not read a Secret,
exec into Tinybird, or create a token.
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
# Shell stubs are used by noexec CI fixtures. A real client is invoked directly.
kubectl_bin="$(type -P kubectl)"
curl_bin="$(type -P curl)"
kubectl() {
  if [[ "$(head -c 2 -- "$kubectl_bin")" == '#!' ]]; then
    bash "$kubectl_bin" "$@"
  else
    "$kubectl_bin" "$@"
  fi
}
curl() {
  if [[ "$(head -c 2 -- "$curl_bin")" == '#!' ]]; then
    bash "$curl_bin" "$@"
  else
    "$curl_bin" "$@"
  fi
}

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

read_runtime_images() {
  deployment_image="$(kubectl -n "$openstatus_namespace" get deployment openstatus-tinybird \
    -o jsonpath='{.spec.template.spec.containers[?(@.name=="tinybird")].image}')"
  pod_image_id="$(kubectl -n "$openstatus_namespace" get pod \
    -l app.kubernetes.io/name=openstatus-tinybird \
    -o jsonpath='{.items[0].status.containerStatuses[?(@.name=="tinybird")].imageID}')"
}

if [[ "$mode" == "--plan" ]]; then
  read_runtime_images
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
      mutation: "create ping_response__v8 only when the management list proves it is absent",
      phase_a_initializes: false,
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
      security_reference: {
        available: "monitoring/openstatus-secret key TINY_BIRD_API_KEY is the application ingest credential only",
        not_admin: ["TINY_BIRD_API_KEY", "TINYBIRD_TOKEN"],
        required_for_presence: "TINYBIRD_ADMIN_TOKEN or TINYBIRD_ADMIN_TOKEN_FILE",
        required_for_rows_after_present: "TINYBIRD_READ_TOKEN or TINYBIRD_READ_TOKEN_FILE",
        required_before_create: "TINYBIRD_CREATE_TOKEN or TINYBIRD_CREATE_TOKEN_FILE",
        missing: "no declarative SOPS or Secret reference exists for the Tinybird Local management credential",
        refused: ["container env scrape", "docs credential copy", "promoting the application key", "kubectl exec"]
      },
      refusal_states: ["authentication-failed", "ingested", "present-unreadable", "identity-unknown", "query-failed", "management-identity-missing"],
      confirmation: "ping_response__v8@ef7691ad"
    }'
  exit 0
fi

if [[ -n "${OPENSTATUS_TINYBIRD_BASE_URL:-}" ]]; then
  [[ "$OPENSTATUS_TINYBIRD_BASE_URL" =~ ^http://(127\.0\.0\.1|localhost):[0-9]+$ ]] || {
    echo "tinybird initialization: OPENSTATUS_TINYBIRD_BASE_URL must be a loopback HTTP origin" >&2
    exit 2
  }
fi

# Credential rejection happens before kubectl, port-forward, and every POST.
openstatus_tinybird_prepare_credential admin || exit 2
if [[ "$openstatus_credential_state" != "ready" ]]; then
  openstatus_tinybird_explain_credential admin
  echo "tinybird initialization: management identity is missing or unusable; no mutation" >&2
  exit 2
fi
unset openstatus_credential_value
if [[ "$mode" == "--execute" ]]; then
  [[ "${CONFIRM_TINYBIRD_INITIALIZE:-}" == "ping_response__v8@ef7691ad" ]] || {
    echo "tinybird initialization: exact confirmation is required" >&2
    exit 2
  }
  openstatus_tinybird_prepare_credential create || exit 2
  if [[ "$openstatus_credential_state" != "ready" ]]; then
    openstatus_tinybird_explain_credential create
    echo "tinybird initialization: create credential is missing or unusable; no mutation" >&2
    exit 2
  fi
  unset openstatus_credential_value
fi
openstatus_tinybird_prepare_credential read || exit 2
case "$openstatus_credential_state" in
  ready | absent) ;;
  *)
    openstatus_tinybird_explain_credential read
    echo "tinybird initialization: read credential source is unusable; no mutation" >&2
    exit 2
    ;;
esac
unset openstatus_credential_value

tmp_dir="$(mktemp -d)"
umask 077
port_forward_pid=""
cleanup() {
  if [[ -n "$port_forward_pid" ]]; then
    kill "$port_forward_pid" 2>/dev/null || true
    wait "$port_forward_pid" 2>/dev/null || true
  fi
  rm -rf -- "$tmp_dir"
}
trap cleanup EXIT

openstatus_tinybird_require_credential admin "$tmp_dir/admin-header" || exit 2
read_header_ready=0
if openstatus_tinybird_optional_header read "$tmp_dir/read-header"; then
  read_header_ready=1
else
  optional_rc=$?
  [[ "$optional_rc" == "1" ]] || exit 2
fi
if [[ "$mode" == "--execute" ]]; then
  openstatus_tinybird_require_credential create "$tmp_dir/create-header" || exit 2
fi
openstatus_tinybird_release_exported_tokens

read_runtime_images
[[ "$pod_image_id" == *@"$runtime_digest" ]] || {
  echo "tinybird initialization: running pod is not the validated digest $runtime_digest" >&2
  exit 1
}
if [[ "$mode" == "--execute" && "$deployment_image" != *@"$runtime_digest" ]]; then
  echo "tinybird initialization: Deployment is not declaratively pinned to $runtime_digest" >&2
  exit 1
fi

base_url="${OPENSTATUS_TINYBIRD_BASE_URL:-}"
if [[ -z "$base_url" ]]; then
  local_port="${OPENSTATUS_TINYBIRD_LOCAL_PORT:-17183}"
  [[ "$local_port" =~ ^[0-9]+$ ]] && (( local_port >= 1 && local_port <= 65535 )) || {
    echo "tinybird initialization: OPENSTATUS_TINYBIRD_LOCAL_PORT is invalid" >&2
    exit 2
  }
  kubectl -n "$openstatus_namespace" port-forward service/openstatus-tinybird "${local_port}:7181" \
    >"$tmp_dir/port-forward.log" 2>&1 &
  port_forward_pid=$!
  for attempt in 1 2 3 4 5 6 7 8 9 10; do
    curl -fsS "http://127.0.0.1:${local_port}/" >/dev/null 2>&1 && break
    if [[ "$attempt" == 10 ]]; then
      echo "tinybird initialization: port-forward did not become ready" >&2
      exit 1
    fi
    sleep 1
  done
  base_url="http://127.0.0.1:${local_port}"
fi

classify_list() {
  local http_code state rc
  http_code="$(curl -sS "$base_url/v0/datasources" \
    -H "@$tmp_dir/admin-header" \
    -o "$tmp_dir/list-response.json" -w '%{http_code}')" || {
    echo "tinybird initialization: datasource list request failed; refusing to guess presence" >&2
    return 1
  }
  set +e
  state="$(bash "$script_dir/classify-openstatus-tinybird-datasources.sh" \
    "$http_code" "$tmp_dir/list-response.json")"
  rc=$?
  set -e
  printf '%s\t%s\n' "$state" "$rc"
}

query='SELECT count() AS result_count, uniqExact(cronTimestamp) AS distinct_intervals, uniqExact(monitorId) AS monitors, uniqExact(region) AS regions FROM ping_response__v8'
query_state() {
  local http_code state rc
  http_code="$(curl -sS -G "$base_url/v0/sql" \
    -H "@$tmp_dir/read-header" --data-urlencode "q=$query" \
    -o "$tmp_dir/query-response.json" -w '%{http_code}')" || {
    echo "tinybird initialization: row query failed; refusing to guess empty or ingested" >&2
    return 1
  }
  set +e
  state="$(bash "$script_dir/classify-openstatus-tinybird-query.sh" \
    "$http_code" "$tmp_dir/query-response.json")"
  rc=$?
  set -e
  printf '%s\t%s\n' "$state" "$rc"
}

finish_check() {
  local state="$1"
  local state_rc="$2"
  printf '%s\n' "$state"
  exit "$state_rc"
}

IFS=$'\t' read -r list_state list_rc < <(classify_list)
case "$list_state" in
  absent)
    list_state="uninitialized"
    list_rc=4
    ;;
  present)
    if (( read_header_ready == 0 )); then
      list_state="present-unreadable"
      list_rc=5
    else
      IFS=$'\t' read -r query_state query_rc < <(query_state)
      if [[ "$query_state" == "uninitialized" ]]; then
        echo "tinybird initialization: management list says present but SQL reports the table missing; refusing to treat that conflict as absence" >&2
        list_state="query-failed"
        list_rc=1
      else
        list_state="$query_state"
        list_rc="$query_rc"
      fi
    fi
    ;;
  authentication-failed | identity-unknown | query-failed) ;;
  *)
    echo "tinybird initialization: datasource list could not be classified; no mutation" >&2
    exit 1
    ;;
esac

if [[ "$mode" == "--check" ]]; then
  finish_check "$list_state" "$list_rc"
fi

case "$list_state" in
  uninitialized) ;;
  *)
    echo "tinybird initialization: preflight is $list_state; no mutation" >&2
    exit 1
    ;;
esac

create_code="$(curl -sS -X POST "$base_url/v0/datasources" \
  -H "@$tmp_dir/create-header" \
  --data-urlencode 'name=ping_response__v8' \
  --data-urlencode "schema=$(awk '
    /^SCHEMA >/ { in_schema=1; next }
    /^ENGINE / { in_schema=0 }
    in_schema { print }
  ' "$datasource_file" | sed '/^[[:space:]]*$/d')" \
  --data-urlencode 'engine=MergeTree' \
  --data-urlencode 'engine_partition_key=toYYYYMM(fromUnixTimestamp64Milli(cronTimestamp))' \
  --data-urlencode 'engine_sorting_key=monitorId, cronTimestamp' \
  -o "$tmp_dir/create-response.json" -w '%{http_code}')" || {
  echo "tinybird initialization: create request failed" >&2
  exit 1
}
[[ "$create_code" == "200" || "$create_code" == "201" ]] || {
  echo "tinybird initialization: create failed with HTTP $create_code" >&2
  exit 1
}

IFS=$'\t' read -r list_state list_rc < <(classify_list)
[[ "$list_state" == "present" && "$list_rc" == "0" ]] || {
  echo "tinybird initialization: create returned success but the management list does not show one target" >&2
  exit 1
}
if (( read_header_ready == 0 )); then
  echo "tinybird initialization: target is present but no accurate read credential was supplied; refusing to claim it is empty" >&2
  exit 1
fi
for attempt in 1 2 3 4 5 6 7 8 9 10; do
  IFS=$'\t' read -r list_state list_rc < <(query_state)
  [[ "$list_state" == "initialized-empty" && "$list_rc" == "0" ]] && {
    echo "tinybird initialization: initialized-empty verified"
    exit 0
  }
  sleep 1
done
echo "tinybird initialization: create returned success but empty datasource verification failed" >&2
exit 1
