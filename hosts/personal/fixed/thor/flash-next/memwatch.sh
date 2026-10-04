#!/usr/bin/env bash
set -euo pipefail

unit=${1:?Usage: memwatch.sh UNIT.service RUNTIME_DIR}
runtime_dir=${2:?Usage: memwatch.sh UNIT.service RUNTIME_DIR}
[[ "$unit" == *.service && "$unit" != -* && "$runtime_dir" == /* && "$runtime_dir" != / ]]
test -d "$runtime_dir"
low_available_since=-1
low_free_since=-1

while true; do
    if ! read -r available free < <(awk '
        /^MemAvailable:/ { a=$2; have_a=1 }
        /^MemFree:/ { f=$2; have_f=1 }
        END { if (have_a && have_f) print a, f }
    ' /proc/meminfo); then
        printf 'Memory guard cannot read host memory; stopping %s\n' "$unit" >&2
        touch "$runtime_dir/memory-stop"
        systemctl stop --no-block "$unit"
        exit 1
    fi
    if (( available < 12 * 1048576 )); then
        if (( low_available_since < 0 )); then low_available_since=$SECONDS; fi
    else
        low_available_since=-1
    fi
    if (( free < 3 * 1048576 && available < 18 * 1048576 )); then
        if (( low_free_since < 0 )); then low_free_since=$SECONDS; fi
    else
        low_free_since=-1
    fi
    if (( (low_available_since >= 0 && SECONDS - low_available_since >= 5) ||
          (low_free_since >= 0 && SECONDS - low_free_since >= 5) )); then
        printf 'Memory guard stopping %s: MemAvailable=%s KiB MemFree=%s KiB\n' "$unit" "$available" "$free"
        touch "$runtime_dir/memory-stop"
        systemctl stop --no-block "$unit"
        exit 0
    fi
    sleep 1
done
