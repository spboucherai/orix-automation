#!/usr/bin/env bash
# ORIX OS Automation
# File: Scripts/release/sign.sh
# Description: Verifies the Developer ID signature, Hardened Runtime, timestamp and entitlements of dist/ORIX OS Automation.app. Signing itself is done by Xcode in the Release build.
#
# Author: Simon-Pierre Boucher
# Contact: contact@spboucher.ai
set -euo pipefail
cd "$(dirname "$0")/../.."
APP="dist/ORIX OS Automation.app"
[[ -d "$APP" ]] || { echo "ERROR: $APP not found. Run Scripts/build/build.sh release first." >&2; exit 1; }
INFO="$(codesign -dvv "$APP" 2>&1)"
fail() { echo "FAIL: $1" >&2; exit 1; }
grep -q "^Authority=Developer ID Application: " <<<"$INFO" || fail "not signed with a Developer ID Application identity"
grep -q "flags=.*runtime" <<<"$INFO" || fail "Hardened Runtime is not enabled"
grep -q "^Timestamp=" <<<"$INFO" || fail "no secure timestamp"
grep -q "^Identifier=ai.spboucher.orix.automation$" <<<"$INFO" || fail "unexpected bundle identifier"
codesign --verify --deep --strict "$APP" || fail "signature does not verify"
ENT="$(codesign -d --entitlements - --xml "$APP" 2>/dev/null | plutil -p - 2>/dev/null || true)"
if grep -q "get-task-allow" <<<"$ENT"; then fail "get-task-allow entitlement present (debug entitlement in a release build)"; fi
echo "Signature : $(sed -n 's/^Authority=\(Developer ID Application: .*\)$/\1/p' <<<"$INFO" | head -1)"
echo "Team      : $(sed -n 's/^TeamIdentifier=//p' <<<"$INFO")"
echo "Runtime   : hardened ($(sed -n 's/^.*flags=\(.*\) hashes.*$/\1/p' <<<"$INFO"))"
echo "Timestamp : $(sed -n 's/^Timestamp=//p' <<<"$INFO")"
echo "Entitlements: ${ENT:-none}"
echo "OK: signature verified."
