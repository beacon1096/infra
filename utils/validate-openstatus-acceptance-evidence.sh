#!/usr/bin/env bash
set -euo pipefail

evidence_file="${1:-}"

if [[ -z "$evidence_file" || "$evidence_file" == "-h" || "$evidence_file" == "--help" ]]; then
  echo "usage: validate-openstatus-acceptance-evidence.sh EVIDENCE.json" >&2
  exit 2
fi
command -v jq >/dev/null 2>&1 || {
  echo "acceptance evidence: jq is required" >&2
  exit 2
}
[[ -r "$evidence_file" ]] || {
  echo "acceptance evidence: cannot read $evidence_file" >&2
  exit 2
}

jq -e '
  (.now_epoch | numbers) as $now |
  (.observation_since_epoch | numbers) as $since |
  (.minimum_real_intervals | numbers) as $minimum |
  (.max_result_age_seconds | numbers) as $result_age |
  (.max_heartbeat_age_seconds | numbers) as $heartbeat_age |
  ($now > 0 and $since > 0 and $since < $now and $minimum > 0 and $result_age > 0 and $heartbeat_age > 0) and
  (.real.monitor_id | strings | length > 0) and
  (.real.region_id | strings | length > 0) and
  (.real.successful_intervals | numbers) >= $minimum and
  .real.latest_status == "success" and
  (.real.last_interval_ms | numbers) >= (($now - $result_age) * 1000) and
  .real.last_interval_ms <= (($now + 60) * 1000) and
  (.real.heartbeat_epoch | numbers) >= ($now - $heartbeat_age) and
  .real.heartbeat_epoch >= $since and
  .real.heartbeat_epoch <= ($now + 60) and
  (.canary.monitor_id | strings | length > 0) and
  (.canary.region_id | strings | length > 0) and
  .real.monitor_id != .canary.monitor_id and
  (.canary.pre_failure_success_intervals | numbers) > 0 and
  (.canary.controlled_failure_intervals | numbers) > 0 and
  (.canary.post_recovery_success_intervals | numbers) > 0 and
  .canary.latest_status == "success" and
  (.canary.last_interval_ms | numbers) >= (($now - $result_age) * 1000) and
  .canary.last_interval_ms <= (($now + 60) * 1000) and
  (.canary.heartbeat_epoch | numbers) >= ($now - $heartbeat_age) and
  .canary.heartbeat_epoch >= $since and
  .canary.heartbeat_epoch <= ($now + 60)
' "$evidence_file" >/dev/null || {
  echo "acceptance evidence: distinct-cycle, latest-result, or heartbeat freshness gate failed" >&2
  exit 1
}

echo "acceptance evidence: distinct successful cycles and fresh latest results/heartbeats passed"
