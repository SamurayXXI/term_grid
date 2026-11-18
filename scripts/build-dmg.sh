#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
app="$("$root/scripts/build-app.sh" release | tail -n 1)"
dmg="$root/build/TermGrid.dmg"
stage="$(mktemp -d "${TMPDIR:-/tmp}/termgrid-dmg.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
cp -R "$app" "$stage/TermGrid.app"
ln -s /Applications "$stage/Applications"
rm -f "$dmg"
hdiutil create -volname "TermGrid" -srcfolder "$stage" -ov -format UDZO "$dmg" >/dev/null
hdiutil verify "$dmg" >/dev/null
echo "$dmg"
