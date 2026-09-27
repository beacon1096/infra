set -euo pipefail
below_available=0
below_free=0
while true; do
    read -r available free < <(awk '/^MemAvailable:/ {a=$2} /^MemFree:/ {f=$2} END {print a, f}' /proc/meminfo)
    if (( available < 12 * 1048576 )); then
        below_available=$((below_available + 1))
    else
        below_available=0
    fi
    if (( free < 3 * 1048576 && available < 18 * 1048576 )); then
        below_free=$((below_free + 1))
    else
        below_free=0
    fi
    if (( below_available >= 5 || below_free >= 5 )) && [[ ! -e /run/thor-inference/memory-stop ]]; then
        printf 'Memory guard stopped inference: MemAvailable=%s KiB MemFree=%s KiB\n' "$available" "$free"
        touch /run/thor-inference/memory-stop
        systemctl stop thor-inference.service
    fi
    sleep 1
done
