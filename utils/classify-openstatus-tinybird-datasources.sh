#!/usr/bin/env bash
set -euo pipefail

http_code="${1:-}"
response_file="${2:-}"
target_name="${3:-ping_response__v8}"

if [[ -z "$http_code" || -z "$response_file" || ! -r "$response_file" ]]; then
  echo "usage: classify-openstatus-tinybird-datasources.sh HTTP_CODE RESPONSE.json [TARGET]" >&2
  exit 2
fi
command -v jq >/dev/null 2>&1 || {
  echo "tinybird datasource classification: jq is required" >&2
  exit 2
}
[[ "$target_name" == "ping_response__v8" ]] || {
  echo "tinybird datasource classification: target identity is not ping_response__v8" >&2
  exit 2
}

if [[ "$http_code" == "401" || "$http_code" == "403" ]]; then
  echo authentication-failed
  exit 3
fi

if [[ "$http_code" != "200" ]]; then
  echo query-failed
  exit 1
fi

if ! jq -e . "$response_file" >/dev/null 2>&1; then
  echo query-failed
  exit 1
fi

if ! jq -e '.datasources | type == "array"' "$response_file" >/dev/null 2>&1; then
  echo identity-unknown
  exit 1
fi

if ! jq -e '
  all(.datasources[];
    (type == "object") and (.name | type == "string") and (.name | length > 0))
' "$response_file" >/dev/null 2>&1; then
  echo identity-unknown
  exit 1
fi

matches="$(jq -r --arg target "$target_name" \
  '[.datasources[].name | select(. == $target)] | length' "$response_file")"
if [[ "$matches" == "0" ]]; then
  echo absent
  exit 4
fi
if [[ "$matches" == "1" ]]; then
  echo present
  exit 0
fi
echo identity-unknown
exit 1
