#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app_dir="$repo_root/wanxiang/kubernetes/apps/monitoring/openstatus/app"

fail() {
  echo "openstatus wiring check: $*" >&2
  exit 1
}

kubectl kustomize "$app_dir" >/dev/null

grep -Fq 'OPENSTATUS_INGEST_URL: http://openstatus-private-location:8080' \
  "$app_dir/configmap.yaml" || fail "probe ingest URL must target the receiver Service"

if grep -Fq 'OPENSTATUS_INGEST_URL: http://openstatus-server:3000' \
  "$app_dir/configmap.yaml"; then
  fail "API server is not the private-probe ingest endpoint"
fi

grep -Fq 'ghcr.io/openstatushq/openstatus-private-location@sha256:76b5bc3941bb0b81c35fd70c2615987d278c3bc61e6c743f8646fba6ddc8318a' \
  "$app_dir/private-location.yaml" || fail "receiver image must stay pinned to the audited revision digest"
grep -Fq 'name: TINYBIRD_TOKEN' "$app_dir/private-location.yaml" || \
  fail "receiver must receive its Go-specific Tinybird token variable"
grep -Fq 'key: TINY_BIRD_API_KEY' "$app_dir/private-location.yaml" || \
  fail "receiver token must reference the existing encrypted Tinybird key"

grep -Fq 'name: openstatus-probe-wanxiang' "$app_dir/probe.yaml" || \
  fail "active Wanxiang probe Deployment is missing"
grep -Fq 'openstatus-private-probe:ef7691a' "$app_dir/probe.yaml" || \
  fail "probe image must stay on the audited source revision"
grep -Fq 'key: OPENSTATUS_KEY' "$app_dir/probe.yaml" || \
  fail "probe must reference the private-location key"
grep -Fq -- '- ./probe.yaml' "$app_dir/kustomization.yaml" || \
  fail "probe manifest is not included by Kustomize"

receiver_replicas="$(sed -n '/^spec:/,/^  selector:/p' "$app_dir/private-location.yaml" | grep -F 'replicas:' | awk '{print $2}')"
probe_replicas="$(sed -n '/^spec:/,/^  selector:/p' "$app_dir/probe.yaml" | grep -F 'replicas:' | awk '{print $2}')"
[[ "$receiver_replicas" == "0" && "$probe_replicas" == "0" ]] || \
  fail "receiver and probe must remain dormant until image publication and Tinybird token gates pass"

echo "openstatus wiring check: OK"
