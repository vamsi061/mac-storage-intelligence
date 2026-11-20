#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
Scripts/build-app.sh --universal
name="Mac Storage Intelligence"
mkdir -p dist
work=$(mktemp -d "$PWD/.build/package.XXXXXXXX")
stage="$work/image"
mount="$work/mounted"
mkdir "$stage" "$mount"
cleanup() {
    if mountpoint=$(stat -f '%d' "$mount") && [[ "$mountpoint" != "$(stat -f '%d' "$work")" ]]; then
        hdiutil detach "$mount" || return
    fi
    rm -rf "$work"
}
trap cleanup EXIT
ditto ".build/$name.app" "$stage/$name.app"
ln -s /Applications "$stage/Applications"
hdiutil create -quiet -volname "$name" -srcfolder "$stage" -format UDZO "$work/app.dmg"
hdiutil verify "$work/app.dmg"
hdiutil attach -readonly -nobrowse -noautoopen -mountpoint "$mount" "$work/app.dmg"
codesign --verify --all-architectures --strict "$mount/$name.app"
cmp "$stage/$name.app/Contents/MacOS/MacStorageIntelligence" "$mount/$name.app/Contents/MacOS/MacStorageIntelligence"
hdiutil detach "$mount"
ditto "$stage/$name.app" "dist/$name.app"
codesign --verify --all-architectures --strict "dist/$name.app"
mv -f "$work/app.dmg" "dist/$name.dmg"
