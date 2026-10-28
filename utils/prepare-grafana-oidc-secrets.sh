#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  printf 'Usage: %s [--generate]\n' "$0" >&2
  printf '\nWrite the two namespace-local SOPS Secret manifests for the approved Grafana OIDC client.\n' >&2
  printf 'Without --generate, read the client secret from the controlling terminal.\n' >&2
}

generate=false
case "${1:-}" in
  "") ;;
  --generate) generate=true ;;
  --help|-h) usage; exit 0 ;;
  *) usage; exit 2 ;;
esac

if [[ $# -gt 1 ]]; then
  usage
  exit 2
fi

root_dir=$(git rev-parse --show-toplevel)
cd "$root_dir"

identity_relative='wanxiang/kubernetes/apps/identity/authentik/app/grafana-oidc.sops.yaml'
monitoring_relative='wanxiang/kubernetes/apps/monitoring/prometheus-stack/app/grafana-oidc.sops.yaml'
identity_path="$root_dir/$identity_relative"
monitoring_path="$root_dir/$monitoring_relative"

if [[ ! -f .sops.yaml ]]; then
  printf 'error: .sops.yaml is missing\n' >&2
  exit 1
fi

if [[ -e "$identity_path" || -e "$monitoring_path" ]]; then
  printf 'error: refusing to overwrite an existing OIDC Secret manifest\n' >&2
  exit 1
fi

if "$generate"; then
  if ! command -v openssl >/dev/null 2>&1; then
    printf 'error: --generate requires openssl\n' >&2
    exit 1
  fi
  client_secret=$(openssl rand -hex 32)
else
  if [[ ! -t 0 && ! -r /dev/tty ]]; then
    printf 'error: no controlling terminal; use --generate or run interactively\n' >&2
    exit 1
  fi
  IFS= read -r -s -p 'Grafana OIDC client secret: ' client_secret < /dev/tty
  printf '\n' >/dev/tty
fi

if [[ -z "$client_secret" ]]; then
  printf 'error: client secret must not be empty\n' >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  printf 'error: python3 is required for safe YAML string serialization\n' >&2
  exit 1
fi

cleanup_outputs=true
cleanup() {
  if "$cleanup_outputs"; then
    rm -f -- "$identity_path" "$monitoring_path"
  fi
}
trap cleanup EXIT

mkdir -p "$(dirname "$identity_path")" "$(dirname "$monitoring_path")"

render_manifest() {
  local secret_name="$1"
  local client_id_key="$2"
  local client_secret_key="$3"

  printf '%s' "$client_secret" | python3 -c '
import json
import sys

secret_name, client_id_key, client_secret_key = sys.argv[1:]
secret = sys.stdin.read()
print("apiVersion: v1")
print("kind: Secret")
print("metadata:")
print(f"  name: {secret_name}")
print("stringData:")
print(f"  {client_id_key}: grafana")
print(f"  {client_secret_key}: {json.dumps(secret)}")
' "$secret_name" "$client_id_key" "$client_secret_key"
}

encrypt_manifest() {
  local relative_path="$1"
  local output_path="$2"
  local secret_name="$3"
  local client_id_key="$4"
  local client_secret_key="$5"

  render_manifest "$secret_name" "$client_id_key" "$client_secret_key" |
    sops --encrypt \
      --filename-override "$relative_path" \
      --input-type yaml \
      --output-type yaml \
      /dev/stdin >"$output_path"
}

encrypt_manifest \
  "$identity_relative" \
  "$identity_path" \
  authentik-grafana-oidc \
  AUTHENTIK_GRAFANA_OIDC_CLIENT_ID \
  AUTHENTIK_GRAFANA_OIDC_CLIENT_SECRET

encrypt_manifest \
  "$monitoring_relative" \
  "$monitoring_path" \
  grafana-oidc \
  GF_AUTH_GENERIC_OAUTH_CLIENT_ID \
  GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET

cleanup_outputs=false
printf 'Encrypted manifests written:\n- %s\n- %s\n' "$identity_relative" "$monitoring_relative"
printf 'They are not consumed until an approved activation change references both files.\n'
