#!/usr/bin/env bash
# ORIX OS Automation
# File: Scripts/release/package.sh
# Description: Builds dist/ORIX-OS-Automation-<version>.dmg (drag-to-install layout) and .zip from dist/ORIX OS Automation.app, signs the DMG and writes SHA-256 checksums.
#
# Author: Simon-Pierre Boucher
# Contact: contact@spboucher.ai
set -euo pipefail
cd "$(dirname "$0")/../.."
APP="dist/ORIX OS Automation.app"
[[ -d "$APP" ]] || { echo "ERROR: $APP not found." >&2; exit 1; }
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="dist/ORIX-OS-Automation-$VERSION.dmg"; ZIP="dist/ORIX-OS-Automation-$VERSION.zip"
IDENTITY="$(codesign -dvv "$APP" 2>&1 | sed -n 's/^Authority=\(Developer ID Application: .*\)$/\1/p' | head -1)"
[[ -n "$IDENTITY" ]] || { echo "ERROR: the app is not signed with a Developer ID identity." >&2; exit 1; }
make_zip() { rm -f "$ZIP"; ditto -c -k --keepParent "$APP" "$ZIP"; echo "built $ZIP"; }
make_dmg() {
  [[ -x build/tools/dmg-background ]] || { mkdir -p build/tools; swiftc -O Scripts/tools/dmg-background.swift -o build/tools/dmg-background; }
  build/tools/dmg-background build/dmg-background.png
  local stage; stage="$(mktemp -d)"; ditto "$APP" "$stage/ORIX OS Automation.app"
  rm -f "$DMG"
  create-dmg --volname "ORIX OS Automation $VERSION" --background build/dmg-background.png --window-pos 200 160 --window-size 660 440 \
    --icon-size 128 --icon "ORIX OS Automation.app" 170 200 --app-drop-link 490 200 --hide-extension "ORIX OS Automation.app" --no-internet-enable \
    "$DMG" "$stage" >/dev/null 2>build/create-dmg.err || { [[ -f "$DMG" ]] || { cat build/create-dmg.err >&2; exit 1; }; }
  rm -rf "$stage"
  codesign --force --timestamp --sign "$IDENTITY" "$DMG"
  codesign --verify "$DMG"; echo "built and signed $DMG"
}
make_checksums() { ( cd dist && shasum -a 256 "$(basename "$DMG")" "$(basename "$ZIP")" | tee SHA256SUMS.txt ); }
case "${1:-all}" in
  zip) make_zip ;;
  dmg) make_dmg ;;
  checksums) make_checksums ;;
  all) make_zip; make_dmg; make_checksums ;;
  *) echo "usage: $0 zip|dmg|checksums|all" >&2; exit 2 ;;
esac
