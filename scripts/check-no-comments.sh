#!/bin/bash
set -uo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
status=0
swift_hits="$(grep -rnE '(^|[^:"])//|/\*' --include='*.swift' Sources Tests 2>/dev/null | grep -v 'swift-tools-version' || true)"
sh_hits="$(grep -nE '#' scripts/*.sh 2>/dev/null | grep -vE ':1:#!' || true)"
if [ -n "$swift_hits" ]; then
    echo "$swift_hits"
    status=1
fi
if [ -n "$sh_hits" ]; then
    echo "$sh_hits"
    status=1
fi
exit "$status"
