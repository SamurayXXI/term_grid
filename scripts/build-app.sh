#!/bin/bash
set -euo pipefail
config="${1:-debug}"
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
swift build -c "$config" --product TermGrid
bin_dir="$(swift build -c "$config" --show-bin-path)"
app="$root/build/TermGrid.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$bin_dir/TermGrid" "$app/Contents/MacOS/TermGrid"
cp "$root/Resources/Info.plist" "$app/Contents/Info.plist"
identity="${TERMGRID_SIGN_IDENTITY:-TermGrid Local Signing}"
if ! security find-certificate -c "$identity" >/dev/null 2>&1; then
    echo "warning: signing identity \"$identity\" not found, signing ad-hoc; Accessibility will be lost on every rebuild" >&2
    identity="-"
fi
codesign --force --sign "$identity" "$app"
echo "$app"
