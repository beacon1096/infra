#!/usr/bin/env bash
set -euo pipefail

excluded_hosts=()
while (($#)); do
  case "$1" in
    --exclude)
      if (($# < 2)) || [[ -z "$2" ]]; then
        echo "--exclude requires a builder host" >&2
        exit 1
      fi
      excluded_hosts+=("$2")
      shift 2
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

: "${GITHUB_ENV:?GITHUB_ENV must name the CI environment file}"
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
builders=$(sed -n 's/^    builders = //p' "$repo_root/wanxiang/kubernetes/components/forgejo-runner-nix/nix-conf.yaml")
if [[ -z "$builders" || "$builders" == *$'\n'* ]]; then
  echo "Expected one builders declaration in the runner ConfigMap" >&2
  exit 1
fi

IFS=';' read -r -a machines <<< "$builders"
selected=()
for machine in "${machines[@]}"; do
  read -r uri settings <<< "$machine"
  exclude=false
  for host in "${excluded_hosts[@]}"; do
    if [[ "${uri##*@}" == "$host" ]]; then
      exclude=true
      break
    fi
  done
  if [[ "$exclude" == false ]]; then
    selected+=("$uri $settings")
  fi
done
if ((${#selected[@]} == 0)); then
  echo "No CI builders remain after exclusions" >&2
  exit 1
fi

builders=$(printf '%s ; ' "${selected[@]}")
builders=${builders% ; }
delimiter="CI_NIX_CONFIG_${RANDOM}_${RANDOM}"
printf '%s\n' "NIX_CONFIG<<$delimiter" "${NIX_CONFIG-}" "max-jobs = 0" "builders = $builders" "$delimiter" >> "$GITHUB_ENV"
