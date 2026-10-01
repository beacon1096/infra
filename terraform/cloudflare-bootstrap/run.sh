#!/usr/bin/env bash
set -euo pipefail
umask 077

if [[ $# -eq 0 || "$1" == "--help" ]]; then
  cat <<'EOF'
Usage: KUBECONFIG=<tfstate kubeconfig> CLOUDFLARE_BOOTSTRAP_API_TOKEN=<admin token> \
         terraform/cloudflare-bootstrap/run.sh <tofu arguments>

Runs OpenTofu against the cloudflare-bootstrap stack, which creates the scoped
`terraform-dns` account token consumed by terraform/cloudflare-dns.

This is a one-off/administrative stack: CLOUDFLARE_BOOTSTRAP_API_TOKEN must be a
privileged Cloudflare token with account API-token write permission. It is
deliberately not read from SOPS, because storing that credential in the repo
would widen the blast radius of a repo compromise.
EOF
  exit 0
fi

: "${KUBECONFIG:?Set KUBECONFIG to the kubeconfig of the cluster holding terraform-state}"
[[ -f "$KUBECONFIG" ]] || { echo "KUBECONFIG must name one file" >&2; exit 1; }
command -v tofu >/dev/null || { echo "Missing command: tofu (try: nix-shell -p opentofu)" >&2; exit 1; }
: "${CLOUDFLARE_BOOTSTRAP_API_TOKEN:?Set CLOUDFLARE_BOOTSTRAP_API_TOKEN (privileged account token)}"
export CLOUDFLARE_API_TOKEN="$CLOUDFLARE_BOOTSTRAP_API_TOKEN"

stack_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
export KUBE_CONFIG_PATH="$KUBECONFIG"

# In a pod the kubernetes backend can fall back to the in-cluster
# ServiceAccount and ignore KUBECONFIG; pin it to the explicit kubeconfig.
if [[ "$1" == "init" ]]; then
  shift
  exec tofu -chdir="$stack_dir" init -backend-config="config_path=$KUBECONFIG" "$@"
fi

exec tofu -chdir="$stack_dir" "$@"
