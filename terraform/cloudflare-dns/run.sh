#!/usr/bin/env bash
set -euo pipefail
umask 077

if [[ $# -eq 0 || "$1" == "--help" ]]; then
  cat <<'EOF'
Usage: KUBECONFIG=<tfstate kubeconfig> [CLOUDFLARE_API_TOKEN=<scoped token>] \
         terraform/cloudflare-dns/run.sh <tofu arguments>

Runs OpenTofu against the cloudflare-dns stack. The scoped token is taken from
CLOUDFLARE_API_TOKEN, or from the SOPS file below when that variable is unset.

  SOPS file : secrets/shared/cloudflare.yaml
  key       : terraform_dns_token
EOF
  exit 0
fi

: "${KUBECONFIG:?Set KUBECONFIG to the kubeconfig of the cluster holding terraform-state}"
[[ -f "$KUBECONFIG" ]] || { echo "KUBECONFIG must name one file" >&2; exit 1; }
command -v tofu >/dev/null || { echo "Missing command: tofu (try: nix-shell -p opentofu)" >&2; exit 1; }

stack_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
export KUBE_CONFIG_PATH="$KUBECONFIG"

if [[ -z "${CLOUDFLARE_API_TOKEN:-}" ]]; then
  secret_file="$stack_dir/../../secrets/shared/cloudflare.yaml"
  if [[ -f "$secret_file" ]]; then
    CLOUDFLARE_API_TOKEN=$(sops --decrypt --extract '["terraform_dns_token"]' "$secret_file")
    export CLOUDFLARE_API_TOKEN
  else
    echo "Set CLOUDFLARE_API_TOKEN, or provide $secret_file with key terraform_dns_token" >&2
    exit 1
  fi
fi

# In a pod the kubernetes backend can fall back to the in-cluster
# ServiceAccount and ignore KUBECONFIG; pin it to the explicit kubeconfig.
if [[ "$1" == "init" ]]; then
  shift
  exec tofu -chdir="$stack_dir" init -backend-config="config_path=$KUBECONFIG" "$@"
fi

exec tofu -chdir="$stack_dir" "$@"
