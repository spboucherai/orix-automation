#!/usr/bin/env bash
# =============================================================================
#                  SP BOUCHER | INFRASTRUCTURE & AUTOMATION
#             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
# =============================================================================
#
# Project          : ORIX OS Automation
# File             : Scripts/release/sign.sh
# Description      : Verifies the Developer ID signature, Hardened Runtime,
#                    timestamp and entitlements of dist/ORIX OS Automation.app.
#                    Signing itself is done by Xcode in the Release build.
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
