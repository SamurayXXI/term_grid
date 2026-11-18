#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
publish=0
if [[ "${1:-}" == "--publish" ]]; then
    publish=1
fi
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
tag="v$version"
if [[ "$(git branch --show-current)" != "main" ]]; then
    echo "release: check out main first" >&2
    exit 1
fi
if [[ -n "$(git status --porcelain)" ]]; then
    echo "release: working tree is not clean" >&2
    exit 1
fi
git fetch --quiet origin main
if [[ "$(git rev-parse HEAD)" != "$(git rev-parse origin/main)" ]]; then
    echo "release: HEAD must equal origin/main" >&2
    exit 1
fi
if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
    echo "release: tag $tag already exists; bump CFBundleShortVersionString in Resources/Info.plist" >&2
    exit 1
fi
if gh release view "$tag" >/dev/null 2>&1; then
    echo "release: GitHub release $tag already exists" >&2
    exit 1
fi
dmg_built="$(scripts/build-dmg.sh | tail -n 1)"
dmg="$root/build/TermGrid-$version.dmg"
mv "$dmg_built" "$dmg"
if [[ "$publish" -eq 0 ]]; then
    echo "dry run: would tag $tag at $(git rev-parse --short HEAD), push it, and create GitHub release $tag with $(basename "$dmg")"
    echo "$dmg"
    exit 0
fi
git tag -a "$tag" -m "TermGrid $version"
git push origin "$tag"
gh release create "$tag" "$dmg" --verify-tag --title "TermGrid $version" --generate-notes
