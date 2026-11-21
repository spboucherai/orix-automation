#!/usr/bin/env bash
# =============================================================================
#                  SP BOUCHER | INFRASTRUCTURE & AUTOMATION
#             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
# =============================================================================
#
# Project          : ORIX OS Automation
# File             : Scripts/release/package.sh
# Description      : Builds dist/ORIX-OS-Automation-<version>.dmg
#                    (drag-to-install layout) and .zip from dist/ORIX OS
#                    Automation.app, signs the DMG and writes SHA-256
#                    checksums.
# Module           : Scripts
# Repository       : https://git.spboucher.ai/orix-automation
# Created          : 2026-11-21
# Last Modified    : 2026-11-21
#
# Author           : Simon-Pierre Boucher
# Position         : Professor of Finance
# Institution      : Université du Québec en Outaouais (UQO)
# Organization     : SP Boucher
# Website          : https://spboucher.ai
# Git              : https://git.spboucher.ai
#
# Preferred Contact: support@spboucher.ai
# Technical Contact: dev@spboucher.ai
# Security/Admin   : admin@spboucher.ai
#
# Copyright (c) 2026
# Simon-Pierre Boucher
# All rights reserved where applicable. This file is governed by the
# applicable project license, copyright notices and relevant law.
# Existing third-party rights and notices remain unaffected.
#
# License          : Proprietary, all rights reserved (see license file)
# License File     : LICENSE
#
# Do not embed credentials, private keys, access tokens,
# certificates or confidential personal information.
#
# =============================================================================
# END OF SP BOUCHER SOURCE HEADER
# =============================================================================

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
