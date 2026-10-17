#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
fixture_dir="$script_dir/fixtures/openstatus-tinybird"
work="$(mktemp -d)"
cleanup() {
  local rc=$?
  if [[ -n "${server_pid:-}" ]]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  rm -rf -- "$work"
  exit "$rc"
}
trap cleanup EXIT

admin_token='synthetic-admin-token'
read_token='synthetic-read-token'
create_token='synthetic-create-token'
app_token='synthetic-app-key'
file_token='synthetic-file-token'
env_token='synthetic-env-token'

install -d -m 0700 "$work/secrets" "$work/tmp" "$work/bin" "$work/out"
printf '%s\n' "$admin_token" >"$work/secrets/admin"
printf '%s\n' "$read_token" >"$work/secrets/read"
printf '%s\n' "$create_token" >"$work/secrets/create"
chmod 600 "$work/secrets/admin" "$work/secrets/read" "$work/secrets/create"

digest='sha256:107829e9143df641e81c7339b0fd7bf9ed97bcea8841f1bb7e9b2fc966049b20'
cat >"$work/bin/kubectl" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "\$*" >>"\$MOCK_KUBECTL_LOG"
if [[ "\$*" == *'get deployment openstatus-tinybird'* || "\$*" == *'get pod '* ]]; then
  printf '%s\n' "example@${digest}"
  exit 0
fi
echo "unexpected kubectl \$*" >&2
exit 99
EOF
real_curl="$(type -P curl)"
cat >"$work/bin/curl" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "\$*" >>"\$CURL_ARGV"
if env | grep -q 'synthetic-' || printf '%s\\n' "\$*" | grep -q 'synthetic-'; then
  printf '%s\\n' leak >>"\$HTTP_LOG"
fi
exec ${real_curl} "\$@"
EOF
chmod 700 "$work/bin/kubectl" "$work/bin/curl"

cat >"$work/server.js" <<'JS'
const fs = require("fs");
const http = require("http");
const scenario = fs.readFileSync(process.env.SCENARIO, "utf8").trim();
const fixtures = process.env.FIXTURES;
const log = fs.createWriteStream(process.env.HTTP_LOG, { flags: "a" });
const present = Buffer.from('{"datasources":[{"name":"ping_response__v8"}]}');
const absent = Buffer.from('{"datasources":[]}');
function send(res, code, body) {
  const data = Buffer.isBuffer(body) ? body : Buffer.from(body);
  res.writeHead(code, { "Content-Length": data.length });
  res.end(data);
}
const server = http.createServer((req, res) => {
  const path = req.url.split("?")[0];
  const auth = req.headers.authorization || "";
  log.write(`${req.method} ${path} auth_len=${auth.length}\n`);
  if (req.method === "GET" && path === "/") return send(res, 200, "ok");
  if (req.method === "GET" && path === "/v0/datasources") {
    if (scenario === "auth401") return send(res, 401, fs.readFileSync(`${fixtures}/uninitialized.json`));
    if (scenario === "auth403") return send(res, 403, '{"error":"Forbidden"}');
    if (scenario === "absent") return send(res, 200, absent);
    if (scenario === "badjson") return send(res, 200, "not-json");
    if (["empty", "ingested", "noread", "sql403"].includes(scenario)) return send(res, 200, present);
    return send(res, 500, "{}");
  }
  if (req.method === "GET" && path === "/v0/sql") {
    if (scenario === "empty") return send(res, 200, fs.readFileSync(`${fixtures}/initialized-empty.json`));
    if (scenario === "ingested") return send(res, 200, fs.readFileSync(`${fixtures}/ingested.json`));
    if (scenario === "sql403") return send(res, 403, '{"error":"Table default.ping_response__v8 does not exist"}');
    return send(res, 500, "{}");
  }
  if (req.method === "POST") {
    req.resume();
    req.on("end", () => send(res, 201, '{"datasource":{"name":"ping_response__v8"}}'));
    return;
  }
  send(res, 404, "{}");
});
server.listen(Number(process.env.PORT), "127.0.0.1");
JS

expect_class() {
  local expected="$1" expected_rc="$2"
  shift 2
  local actual rc
  set +e
  actual="$("$@" 2>"$work/class.err")"
  rc=$?
  set -e
  [[ "$actual" == "$expected" && "$rc" == "$expected_rc" ]]
  ! grep -q 'synthetic-' "$work/class.err"
}

expect_class absent 4 bash "$script_dir/classify-openstatus-tinybird-datasources.sh" 200 "$fixture_dir/datasources-absent.json"
expect_class absent 4 bash "$script_dir/classify-openstatus-tinybird-datasources.sh" 200 "$fixture_dir/datasources-other.json"
expect_class present 0 bash "$script_dir/classify-openstatus-tinybird-datasources.sh" 200 "$fixture_dir/datasources-present.json"
expect_class authentication-failed 3 bash "$script_dir/classify-openstatus-tinybird-datasources.sh" 401 "$fixture_dir/uninitialized.json"
expect_class authentication-failed 3 bash "$script_dir/classify-openstatus-tinybird-datasources.sh" 403 "$fixture_dir/authentication-failed.json"
expect_class query-failed 1 bash "$script_dir/classify-openstatus-tinybird-datasources.sh" 404 "$fixture_dir/datasources-absent.json"
expect_class query-failed 1 bash "$script_dir/classify-openstatus-tinybird-datasources.sh" 200 "$fixture_dir/not-json.txt"
expect_class identity-unknown 1 bash "$script_dir/classify-openstatus-tinybird-datasources.sh" 200 "$fixture_dir/datasources-bad-shape.json"
expect_class identity-unknown 1 bash "$script_dir/classify-openstatus-tinybird-datasources.sh" 200 "$fixture_dir/datasources-duplicate.json"
expect_class authentication-failed 3 bash "$script_dir/classify-openstatus-tinybird-query.sh" 401 "$fixture_dir/uninitialized.json"
expect_class authentication-failed 3 bash "$script_dir/classify-openstatus-tinybird-query.sh" 403 "$fixture_dir/uninitialized.json"

(
  # shellcheck source=utils/openstatus-tinybird-auth.sh
  source "$script_dir/openstatus-tinybird-auth.sh"
  TINYBIRD_ADMIN_TOKEN="$admin_token" openstatus_tinybird_prepare_credential admin
  [[ "$openstatus_credential_state" == "ready" ]]
  header="$work/header"
  openstatus_tinybird_write_bearer_header "$header"
  [[ "$(stat -c %a "$header")" == "600" ]]
  expected="$work/expected-header"
  printf 'Authorization: Bearer %s\n' "$admin_token" >"$expected"
  cmp -s "$header" "$expected"
  rm -f -- "$header" "$expected"
  TINYBIRD_ADMIN_TOKEN="$env_token" TINYBIRD_ADMIN_TOKEN_FILE="$work/secrets/admin" \
    openstatus_tinybird_prepare_credential admin
  [[ "$openstatus_credential_state" == "ambiguous" ]]
  unset TINYBIRD_ADMIN_TOKEN
  TINYBIRD_ADMIN_TOKEN_FILE="$work/secrets/missing" openstatus_tinybird_prepare_credential admin
  [[ "$openstatus_credential_state" == "missing-file" ]]
  TINYBIRD_ADMIN_TOKEN_FILE="$work/secrets" openstatus_tinybird_prepare_credential admin
  [[ "$openstatus_credential_state" == "unreadable" ]]
  printf '\n' >"$work/secrets/empty"
  TINYBIRD_ADMIN_TOKEN_FILE="$work/secrets/empty" openstatus_tinybird_prepare_credential admin
  [[ "$openstatus_credential_state" == "illegal" ]]
  printf '%s\n\n' "$admin_token" >"$work/secrets/twonew"
  TINYBIRD_ADMIN_TOKEN_FILE="$work/secrets/twonew" openstatus_tinybird_prepare_credential admin
  [[ "$openstatus_credential_state" == "illegal" ]]
  printf '%s\n' "${admin_token} injected" >"$work/secrets/space"
  TINYBIRD_ADMIN_TOKEN_FILE="$work/secrets/space" openstatus_tinybird_prepare_credential admin
  [[ "$openstatus_credential_state" == "illegal" ]]
  printf '%s\n' "$admin_token" >"$work/secrets/newline-ok"
  TINYBIRD_ADMIN_TOKEN_FILE="$work/secrets/newline-ok" openstatus_tinybird_prepare_credential admin
  [[ "$openstatus_credential_state" == "ready" ]]
  TINY_BIRD_API_KEY="$app_token" openstatus_tinybird_prepare_credential admin
  [[ "$openstatus_credential_state" == "absent" ]]
)

server_pid=""
start_server() {
  if [[ -n "${server_pid:-}" ]]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  printf '%s\n' "$1" >"$work/scenario"
  : >"$work/http.log"
  : >"$work/curl.argv"
  : >"$work/kubectl.log"
  PORT="$port" SCENARIO="$work/scenario" HTTP_LOG="$work/http.log" FIXTURES="$fixture_dir" \
    node "$work/server.js" &
  server_pid=$!
  local attempt
  for attempt in 1 2 3 4 5 6 7 8 9 10; do
    curl -fsS "http://127.0.0.1:${port}/" >/dev/null 2>&1 && return 0
    sleep 0.1
  done
  echo "tinybird preinit fixture: HTTP server did not start" >&2
  return 1
}
port="$(node -e 'const net=require("net"); const s=net.createServer(); s.listen(0,"127.0.0.1",()=>{console.log(s.address().port); s.close();});')"

run_init() {
  local expected_rc="$1"
  shift
  local rc
  set +e
  env -u TINYBIRD_ADMIN_TOKEN -u TINYBIRD_READ_TOKEN -u TINYBIRD_CREATE_TOKEN \
    -u TINYBIRD_ADMIN_TOKEN_FILE -u TINYBIRD_READ_TOKEN_FILE -u TINYBIRD_CREATE_TOKEN_FILE \
    -u TINY_BIRD_API_KEY \
    TMPDIR="$work/tmp" PATH="$work/bin:$PATH" \
    MOCK_KUBECTL_LOG="$work/kubectl.log" CURL_ARGV="$work/curl.argv" HTTP_LOG="$work/http.log" \
    OPENSTATUS_TINYBIRD_BASE_URL="http://127.0.0.1:${port}" \
    "$@" \
    bash "$script_dir/initialize-openstatus-tinybird.sh" "$mode" \
    >"$work/out/stdout" 2>"$work/out/stderr"
  rc=$?
  set -e
  [[ "$rc" == "$expected_rc" ]]
  ! grep -q 'synthetic-' "$work/out/stdout" "$work/out/stderr"
  ! grep -q 'leak' "$work/http.log" || {
    echo "tinybird preinit fixture: credential leaked to argv or child environment" >&2
    return 1
  }
  ! grep -R -q 'synthetic-' "$work/tmp" || {
    echo "tinybird preinit fixture: credential file survived cleanup" >&2
    return 1
  }
}

mode="--check"
start_server absent
run_init 4 TINYBIRD_ADMIN_TOKEN_FILE="$work/secrets/admin"
[[ "$(<"$work/out/stdout")" == "uninitialized" ]]
! grep -q '/v0/sql' "$work/http.log"
grep -q 'GET /v0/datasources auth_len=' "$work/http.log"

start_server auth401
run_init 3 TINYBIRD_ADMIN_TOKEN_FILE="$work/secrets/admin"
[[ "$(<"$work/out/stdout")" == "authentication-failed" ]]

start_server auth403
run_init 3 TINYBIRD_ADMIN_TOKEN="$admin_token"
[[ "$(<"$work/out/stdout")" == "authentication-failed" ]]

start_server empty
run_init 0 TINYBIRD_ADMIN_TOKEN_FILE="$work/secrets/admin" TINYBIRD_READ_TOKEN_FILE="$work/secrets/read"
[[ "$(<"$work/out/stdout")" == "initialized-empty" ]]
grep -q 'GET /v0/sql' "$work/http.log"

start_server ingested
run_init 0 TINYBIRD_ADMIN_TOKEN_FILE="$work/secrets/admin" TINYBIRD_READ_TOKEN_FILE="$work/secrets/read"
[[ "$(<"$work/out/stdout")" == "ingested" ]]

start_server noread
run_init 5 TINYBIRD_ADMIN_TOKEN_FILE="$work/secrets/admin"
[[ "$(<"$work/out/stdout")" == "present-unreadable" ]]
! grep -q '/v0/sql' "$work/http.log"

start_server sql403
run_init 3 TINYBIRD_ADMIN_TOKEN_FILE="$work/secrets/admin" TINYBIRD_READ_TOKEN_FILE="$work/secrets/read"
[[ "$(<"$work/out/stdout")" == "authentication-failed" ]]

start_server badjson
run_init 1 TINYBIRD_ADMIN_TOKEN_FILE="$work/secrets/admin"
[[ "$(<"$work/out/stdout")" == "query-failed" ]]

start_server absent
run_init 2 TINY_BIRD_API_KEY="$app_token"
[[ ! -s "$work/kubectl.log" ]] && ! grep -q '/v0/' "$work/http.log"
grep -q 'management identity is missing or unusable' "$work/out/stderr"

run_init 2 TINYBIRD_ADMIN_TOKEN="$env_token" TINYBIRD_ADMIN_TOKEN_FILE="$work/secrets/admin"
! grep -q '/v0/' "$work/http.log"

printf '%s\nX-Injected: yes\n' "$admin_token" >"$work/secrets/injected"
run_init 2 TINYBIRD_ADMIN_TOKEN_FILE="$work/secrets/injected"
! grep -q '/v0/' "$work/http.log"

mode="--execute"
start_server absent
run_init 2 CONFIRM_TINYBIRD_INITIALIZE='ping_response__v8@ef7691ad' \
  TINYBIRD_CREATE_TOKEN_FILE="$work/secrets/create"
[[ ! -s "$work/kubectl.log" ]] && ! grep -q '/v0/' "$work/http.log"

run_init 2 CONFIRM_TINYBIRD_INITIALIZE='ping_response__v8@ef7691ad' \
  TINYBIRD_ADMIN_TOKEN_FILE="$work/secrets/admin"
! grep -q '/v0/' "$work/http.log"

start_server auth401
run_init 1 CONFIRM_TINYBIRD_INITIALIZE='ping_response__v8@ef7691ad' \
  TINYBIRD_ADMIN_TOKEN_FILE="$work/secrets/admin" TINYBIRD_CREATE_TOKEN_FILE="$work/secrets/create"
! grep -q 'POST ' "$work/http.log"

start_server noread
run_init 1 CONFIRM_TINYBIRD_INITIALIZE='ping_response__v8@ef7691ad' \
  TINYBIRD_ADMIN_TOKEN_FILE="$work/secrets/admin" TINYBIRD_CREATE_TOKEN_FILE="$work/secrets/create"
! grep -q 'POST ' "$work/http.log"

printf '%s\n' "$read_token" >"$work/secrets/bad-read"
printf '\n%s\n' 'broken' >>"$work/secrets/bad-read"
start_server absent
run_init 2 CONFIRM_TINYBIRD_INITIALIZE='ping_response__v8@ef7691ad' \
  TINYBIRD_ADMIN_TOKEN_FILE="$work/secrets/admin" \
  TINYBIRD_CREATE_TOKEN_FILE="$work/secrets/create" \
  TINYBIRD_READ_TOKEN_FILE="$work/secrets/bad-read"
[[ ! -s "$work/kubectl.log" ]] && ! grep -q '/v0/' "$work/http.log"

deadline="$(( $(date -u +%s) + 30 ))"
: >"$work/kubectl.log"
set +e
env -u TINYBIRD_ADMIN_TOKEN -u TINYBIRD_ADMIN_TOKEN_FILE \
  TMPDIR="$work/tmp" PATH="$work/bin:$PATH" MOCK_KUBECTL_LOG="$work/kubectl.log" \
  RUN_ID=ab BASELINE_PURPOSE=pre-init INITIALIZE_TINYBIRD=never \
  BASELINE_FILE="$work/out/baseline.json" BACKUP_MANIFEST="$work/out/backup.yaml" \
  BACKUP_SCOPE_FILE="$work/out/scope.json" QUIESCE_DEADLINE_EPOCH="$deadline" \
  TINY_BIRD_API_KEY="$app_token" TINYBIRD_READ_TOKEN="$read_token" \
  bash "$script_dir/start-openstatus-baseline-backup.sh" \
  >"$work/out/stdout" 2>"$work/out/stderr"
start_rc=$?
set -e
[[ "$start_rc" == "2" ]]
[[ ! -s "$work/kubectl.log" ]]
! grep -q 'synthetic-' "$work/out/stdout" "$work/out/stderr"
grep -q 'admin identity is absent' "$work/out/stderr"

echo "OpenStatus Tinybird pre-init fixtures: presence, auth, rows, file credentials, and pre-mutation refusal passed"
