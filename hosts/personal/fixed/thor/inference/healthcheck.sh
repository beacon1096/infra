set -euo pipefail
counter=/run/thor-inference/health-failures
snapshot() {
    systemctl show --property=InvocationID --property=ActiveState thor-inference.service
}
before=$(snapshot)
if [[ -e /run/thor-inference/memory-stop || "$before" != *"ActiveState=active"* ]]; then
    rm -f "$counter"
    exit 0
fi
started=$(systemctl show --property=ActiveEnterTimestampMonotonic --value thor-inference.service)
uptime_seconds=$(awk '{print int($1)}' /proc/uptime)
if (( uptime_seconds - started / 1000000 < 180 )); then
    exit 0
fi
healthy=false
if curl --silent --show-error --fail --connect-timeout 5 --max-time 60 http://127.0.0.1:8888/health_generate >/dev/null; then
    healthy=true
fi
after=$(snapshot)
if [[ -e /run/thor-inference/memory-stop || "$before" != "$after" || "$after" != *"ActiveState=active"* ]]; then
    rm -f "$counter"
    exit 0
fi
if "$healthy"; then
    rm -f "$counter"
    exit 0
fi
failures=0
[[ ! -f "$counter" ]] || read -r failures < "$counter"
failures=$((failures + 1))
printf '%s\n' "$failures" > "$counter"
printf 'Inference health check failed (%s/3)\n' "$failures"
if (( failures >= 3 )) && [[ ! -e /run/thor-inference/memory-stop && "$before" == "$(snapshot)" ]]; then
    rm -f "$counter"
    systemctl --no-block try-restart thor-inference.service
fi
