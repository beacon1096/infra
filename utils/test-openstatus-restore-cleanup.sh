#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
real_kubectl="$(command -v kubectl)"
test_tmp_dir="$(mktemp -d)"
trap 'rm -rf -- "$test_tmp_dir"' EXIT

cat >"$test_tmp_dir/kubectl" <<'EOF'
#!/bin/bash
set -euo pipefail

if [[ "${1:-}" == "apply" ]]; then
  exec "$REAL_KUBECTL" "$@"
fi
if [[ "$*" == "get namespace openstatus-restore-fixture -o json" ]]; then
  exit 1
fi
if [[ "$*" == "get pv -l openstatus.beaco.works/restore-run=fixture -o json" ]]; then
  printf '%s\n' '{"items":[{"metadata":{"name":"osr-fixture-libsql"}}]}'
  exit 0
fi
if [[ "$*" == "-n storage get volumes.longhorn.io -l openstatus.beaco.works/restore-run=fixture -o json" ]]; then
  printf '%s\n' '{"items":[{"metadata":{"name":"osr-fixture-libsql"}}]}'
  exit 0
fi
if [[ "$*" == "get pv osr-fixture-libsql -o json" ]]; then
  handle="osr-fixture-libsql"
  [[ "${BAD_BINDING:-0}" == "1" ]] && handle="wrong-volume"
  printf '{"metadata":{"name":"osr-fixture-libsql","labels":{"openstatus.beaco.works/restore-run":"fixture"}},"spec":{"persistentVolumeReclaimPolicy":"Retain","storageClassName":"longhorn","claimRef":{"namespace":"openstatus-restore-fixture","name":"restore-libsql-data"},"csi":{"driver":"driver.longhorn.io","volumeHandle":"%s"}}}\n' "$handle"
  exit 0
fi
if [[ "$*" == "-n storage get volumes.longhorn.io osr-fixture-libsql -o json" ]]; then
  printf '%s\n' '{"metadata":{"name":"osr-fixture-libsql","labels":{"openstatus.beaco.works/restore-run":"fixture"}}}'
  exit 0
fi
exit 1
EOF
chmod +x "$test_tmp_dir/kubectl"

plan_output="$(
  PATH="$test_tmp_dir:$PATH" REAL_KUBECTL="$real_kubectl" \
    RUN_ID=fixture RESTORE_MANIFEST="$script_dir/fixtures/openstatus-restore/partial-plan.yaml" \
    bash "$script_dir/cleanup-openstatus-restore-drill.sh" --plan
)"
grep -q 'namespace/openstatus-restore-fixture (absent)' <<<"$plan_output"
grep -q 'persistentvolume/osr-fixture-libsql (present' <<<"$plan_output"
grep -q 'persistentvolume/osr-fixture-tinybird (absent' <<<"$plan_output"

if PATH="$test_tmp_dir:$PATH" REAL_KUBECTL="$real_kubectl" BAD_BINDING=1 \
  RUN_ID=fixture RESTORE_MANIFEST="$script_dir/fixtures/openstatus-restore/partial-plan.yaml" \
  bash "$script_dir/cleanup-openstatus-restore-drill.sh" --plan >/dev/null 2>&1; then
  echo "cleanup fixture: bad PV binding unexpectedly passed" >&2
  exit 1
fi

echo "cleanup fixture: pre-create/partial plan passed; bad PV binding was rejected"
