#!/usr/bin/env bash
set -euo pipefail

http_code="${1:-}"
response_file="${2:-}"

if [[ -z "$http_code" || -z "$response_file" || ! -r "$response_file" ]]; then
  echo "usage: classify-openstatus-tinybird-query.sh HTTP_CODE RESPONSE.json" >&2
  exit 2
fi
command -v jq >/dev/null 2>&1 || {
  echo "tinybird query classification: jq is required" >&2
  exit 2
}

if [[ "$http_code" == "401" || "$http_code" == "403" ]]; then
  echo authentication-failed
  exit 3
fi

if [[ "$http_code" == "200" ]] && jq -e '
  (.data | type == "array" and length == 1) and
  (.data[0].result_count | tonumber? | type == "number")
' "$response_file" >/dev/null; then
  rows="$(jq -r '.data[0].result_count | tonumber' "$response_file")"
  if (( rows == 0 )); then
    echo initialized-empty
  else
    echo ingested
  fi
  exit 0
fi

error_text="$(jq -r '.error // .message // ""' "$response_file" 2>/dev/null || true)"
if [[ "$http_code" == "400" || "$http_code" == "404" ]] &&
  [[ "$error_text" =~ ([Uu]nknown[[:space:]]table|doesn.t[[:space:]]exist|not[[:space:]]exist|UNKNOWN_TABLE) ]] &&
  [[ "$error_text" == *"ping_response__v8"* ]]; then
  echo uninitialized
  exit 4
fi

echo query-failed
exit 1
