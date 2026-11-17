#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
clt=/Library/Developer/CommandLineTools
exec swift test \
    -Xswiftc -F -Xswiftc "$clt/Library/Developer/Frameworks" \
    -Xlinker -rpath -Xlinker "$clt/Library/Developer/Frameworks" \
    -Xlinker -rpath -Xlinker "$clt/Library/Developer/usr/lib" \
    "$@"
