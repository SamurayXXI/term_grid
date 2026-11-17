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
codesign --force --sign - "$app"
echo "$app"
