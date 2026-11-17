#!/bin/bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
dir="$root/.omc/evidence/probe"
bundle_id="local.termgrid.TermGrid"

if [ "${1:-}" = "--reset" ]; then
    pkill -x TermGrid || true
    tccutil reset Accessibility "$bundle_id"
    shift
fi

request="${1:-$dir/req.json}"
out="${2:-$dir/out.ndjson}"

case "$request" in /*) ;; *) request="$PWD/$request" ;; esac
case "$out" in /*) ;; *) out="$PWD/$out" ;; esac

if [ ! -f "$request" ]; then
    echo "request not found: $request" >&2
    exit 1
fi

if [ ! -d "$root/build/TermGrid.app" ]; then
    echo "build/TermGrid.app missing, run scripts/build-app.sh debug" >&2
    exit 1
fi

pkill -x TermGrid || true
while pgrep -x TermGrid >/dev/null; do
    sleep 0.2
done

rm -f "$out"
read -r -a extra_args <<< "${PROBE_APP_ARGS:-}"
open "$root/build/TermGrid.app" --args ${extra_args[@]+"${extra_args[@]}"} --probe "$request" --probe-out "$out"

finished=0
for _ in $(seq 1 1000); do
    if [ -s "$out" ] && ! pgrep -x TermGrid >/dev/null; then
        finished=1
        break
    fi
    sleep 0.2
done

if [ "$finished" != 1 ]; then
    echo "timeout waiting for probe to finish" >&2
    exit 1
fi

lines=$(wc -l < "$out" | tr -d ' ')
echo "probe finished: $lines lines in $out"
if grep -q '"type":"error"' "$out"; then
    grep '"type":"error"' "$out" >&2
    exit 2
fi
