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

cleanup_outputs=true
cleanup() {
  if "$cleanup_outputs"; then
    rm -f -- "$identity_path" "$monitoring_path"
  fi
}
trap cleanup EXIT

mkdir -p "$(dirname "$identity_path")" "$(dirname "$monitoring_path")"

sops --encrypt \
  --filename-override "$identity_relative" \
  --input-type yaml \
  --output-type yaml \
  /dev/stdin >"$identity_path" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: authentik-grafana-oidc
stringData:
  AUTHENTIK_GRAFANA_OIDC_CLIENT_ID: grafana
  AUTHENTIK_GRAFANA_OIDC_CLIENT_SECRET: $client_secret
EOF

sops --encrypt \
  --filename-override "$monitoring_relative" \
  --input-type yaml \
  --output-type yaml \
  /dev/stdin >"$monitoring_path" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: grafana-oidc
stringData:
  GF_AUTH_GENERIC_OAUTH_CLIENT_ID: grafana
  GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET: $client_secret
EOF

cleanup_outputs=false
printf 'Encrypted manifests written:\n- %s\n- %s\n' "$identity_relative" "$monitoring_relative"
printf 'They are not consumed until an approved activation change references both files.\n'
