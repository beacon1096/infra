#!/usr/bin/env bash
set -euo pipefail

mcp_url="${OPENSTATUS_MCP_URL:-https://openstatus.beaco.works/mcp}"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  cat >&2 <<'EOF'
Verify the fixed OpenStatus MCP endpoint with a dedicated Read-only key.

Usage:
  OPENSTATUS_MCP_KEY=os_... \
    [OPENSTATUS_MCP_URL=https://openstatus.beaco.works/mcp] \
    bash utils/check-openstatus-mcp-readonly.sh

The key is placed only in a mode-0600 temporary curl header file, is never
printed, and must come from the operator's secret store. The script performs
only initialize, tools/list, and list_monitors.
EOF
  exit 0
fi

for command in curl jq sed; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "mcp check: $command is required" >&2
    exit 2
  }
done
[[ "${OPENSTATUS_MCP_KEY:-}" == os_* ]] || {
  echo "mcp check: OPENSTATUS_MCP_KEY must be a dedicated os_ API key" >&2
  exit 2
}
[[ "$mcp_url" == https://* || "$mcp_url" == http://127.0.0.1:* ]] || {
  echo "mcp check: URL must use HTTPS (or loopback HTTP for a port-forward)" >&2
  exit 2
}

mcp_tmp_dir="$(mktemp -d)"
cleanup_mcp_tmp() {
  rm -rf -- "$mcp_tmp_dir"
}
trap cleanup_mcp_tmp EXIT
umask 077
printf 'x-openstatus-key: %s\n' "$OPENSTATUS_MCP_KEY" >"$mcp_tmp_dir/auth-header"

common_headers=(
  -H 'content-type: application/json'
  -H 'accept: application/json, text/event-stream'
)

unauth_status="$(curl -sS -o "$mcp_tmp_dir/unauth-body" -w '%{http_code}' \
  -X POST "$mcp_url" "${common_headers[@]}" \
  --data '{"jsonrpc":"2.0","id":0,"method":"tools/list"}')"
[[ "$unauth_status" == "401" ]] || {
  echo "mcp check: unauthenticated request returned HTTP $unauth_status, expected 401 (307 means Gateway misrouting)" >&2
  exit 1
}

extract_json_rpc() {
  local source_file="$1"
  local destination_file="$2"
  if jq -e . "$source_file" >/dev/null 2>&1; then
    jq -c . "$source_file" >"$destination_file"
    return
  fi
  sed -n 's/^data:[[:space:]]*//p' "$source_file" | sed -n '1p' >"$destination_file"
  jq -e . "$destination_file" >/dev/null || {
    echo "mcp check: response was neither JSON nor a JSON SSE data frame" >&2
    return 1
  }
}

rpc_post() {
  local name="$1"
  local payload="$2"
  local status
  status="$(curl -sS -o "$mcp_tmp_dir/${name}.raw" -w '%{http_code}' \
    -X POST "$mcp_url" "${common_headers[@]}" \
    -H "@$mcp_tmp_dir/auth-header" --data "$payload")"
  [[ "$status" == "200" ]] || {
    echo "mcp check: $name returned HTTP $status" >&2
    return 1
  }
  extract_json_rpc "$mcp_tmp_dir/${name}.raw" "$mcp_tmp_dir/${name}.json"
  jq -e '.error == null' "$mcp_tmp_dir/${name}.json" >/dev/null || {
    echo "mcp check: $name returned a JSON-RPC error" >&2
    return 1
  }
}

rpc_post initialize \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"openstatus-readonly-acceptance","version":"1.0"}}}'
jq -e '.result.serverInfo.name | length > 0' "$mcp_tmp_dir/initialize.json" >/dev/null || {
  echo "mcp check: initialize omitted serverInfo" >&2
  exit 1
}

rpc_post tools-list \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'
jq -e '
  (.result.tools | length) > 0 and
  any(.result.tools[]; .name == "list_monitors") and
  all(.result.tools[];
    .annotations.readOnlyHint == true and
    (.name | test("^(create_|update_|add_|resolve_)") | not))
' "$mcp_tmp_dir/tools-list.json" >/dev/null || {
  echo "mcp check: tools/list exposed a write-capable tool or omitted list_monitors" >&2
  exit 1
}

rpc_post list-monitors \
  '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"list_monitors","arguments":{"page":1,"perPage":25}}}'
jq -e '
  .result.isError != true and
  (.result.structuredContent.items | type) == "array" and
  (.result.structuredContent.pagination.totalSize | type) == "number"
' "$mcp_tmp_dir/list-monitors.json" >/dev/null || {
  echo "mcp check: list_monitors did not return the expected read-only shape" >&2
  exit 1
}

tool_count="$(jq -r '.result.tools | length' "$mcp_tmp_dir/tools-list.json")"
monitor_count="$(jq -r '.result.structuredContent.pagination.totalSize' "$mcp_tmp_dir/list-monitors.json")"
echo "mcp check: initialize passed; tools=$tool_count all read-only; list_monitors passed with total=$monitor_count"
