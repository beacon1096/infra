#!/usr/bin/env bash
set -euo pipefail
umask 077

if [[ $# -eq 0 || "$1" == "--help" ]]; then
  cat <<'EOF'
Usage: KUBECONFIG=<wanxiang kubeconfig> [AUTHENTIK_TERRAFORM_SECRETS=<path>] \
         terraform/authentik-wanxiang/run.sh <tofu arguments>

Runs OpenTofu against the authentik-wanxiang stack. The Authentik API token and
the stack's four sensitive variables live in the private SOPS bundle, never in
this public repo:

  default file : <sibling infra-private>/secrets/infrastructure/authentik-terraform.yaml
  keys         : authentik_token, netlock_radius_shared_secret,
                 anyconn_rac_settings, rac_rdp_beaco_settings,
                 rac_rdp_beacon_settings

Set AUTHENTIK_TOKEN to skip reading the token from the bundle, and
AUTHENTIK_TERRAFORM_SECRETS to point at a bundle outside the default sibling
checkout. Variables are injected as TF_VAR_* and are never written to disk.
EOF
  exit 0
fi

: "${KUBECONFIG:?Set KUBECONFIG to the kubeconfig of the cluster holding terraform-state}"
[[ -f "$KUBECONFIG" ]] || { echo "KUBECONFIG must name one file" >&2; exit 1; }
for tool in tofu sops jq; do
  command -v "$tool" >/dev/null || { echo "Missing command: $tool" >&2; exit 1; }
done

stack_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
export KUBE_CONFIG_PATH="$KUBECONFIG"

secrets_file="${AUTHENTIK_TERRAFORM_SECRETS:-$stack_dir/../../../infra-private/secrets/infrastructure/authentik-terraform.yaml}"
[[ -f "$secrets_file" ]] || {
  echo "Authentik credential bundle not found: $secrets_file" >&2
  echo "Set AUTHENTIK_TERRAFORM_SECRETS to infra-private/secrets/infrastructure/authentik-terraform.yaml" >&2
  exit 1
}

if [[ -z "${AUTHENTIK_TOKEN:-}" ]]; then
  AUTHENTIK_TOKEN=$(sops --decrypt --extract '["authentik_token"]' "$secrets_file")
  export AUTHENTIK_TOKEN
fi

# Export the stack's sensitive variables from the same bundle. Reading once via
# jq @sh keeps them shell-safe without a decrypted tfvars file on disk.
eval "$(sops --decrypt --output-type json "$secrets_file" | jq -r '
  "export TF_VAR_netlock_radius_shared_secret=\(.netlock_radius_shared_secret|@sh)\n" +
  "export TF_VAR_anyconn_rac_settings=\(.anyconn_rac_settings|@sh)\n" +
  "export TF_VAR_rac_rdp_beaco_settings=\(.rac_rdp_beaco_settings|@sh)\n" +
  "export TF_VAR_rac_rdp_beacon_settings=\(.rac_rdp_beacon_settings|@sh)"
')"

# In a pod the kubernetes backend can fall back to the in-cluster
# ServiceAccount and ignore KUBECONFIG; pin it to the explicit kubeconfig.
if [[ "$1" == "init" ]]; then
  shift
  exec tofu -chdir="$stack_dir" init -backend-config="config_path=$KUBECONFIG" "$@"
fi

exec tofu -chdir="$stack_dir" "$@"
