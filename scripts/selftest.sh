#!/bin/bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
limit="${SELFTEST_LIMIT:-120}"

if [ ! -d "$root/build/TermGrid.app" ]; then
    echo "build/TermGrid.app missing, run scripts/build-app.sh debug" >&2
    exit 1
fi

started=""

resume_stopped() {
    [ -n "$started" ] || return 0
    local pid
    /usr/bin/log show --start "$started" --style compact --predicate 'subsystem == "local.termgrid"' 2>/dev/null \
        | grep -oE 'selftest stopped pid=[0-9]+' | grep -oE '[0-9]+$' | sort -u \
        | while read -r pid; do
            kill -CONT "$pid" 2>/dev/null || true
        done || true
}

trap resume_stopped EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

pkill -x TermGrid || true
while pgrep -x TermGrid >/dev/null; do
    sleep 0.2
done

started=$(date '+%Y-%m-%d %H:%M:%S')
open "$root/build/TermGrid.app" --args "$@"

for _ in $(seq 1 50); do
    pgrep -x TermGrid >/dev/null && break
    sleep 0.2
done

finished=0
for _ in $(seq 1 $((limit * 5))); do
    if ! pgrep -x TermGrid >/dev/null; then
        finished=1
        break
    fi
    sleep 0.2
done

/usr/bin/log show --start "$started" --style compact --predicate 'subsystem == "local.termgrid"' \
    | grep -E 'apply |selftest|ax timeout|windows discovered|no windows|enhanced ui|fit |cell status|drag |dividers |detached|cell empty|app terminated|main stall|observe |event |screen|edge resize|background cursor' || true

if [ "$finished" != 1 ]; then
    echo "timeout waiting for selftest to finish" >&2
    pkill -x TermGrid || true
    exit 1
fi
