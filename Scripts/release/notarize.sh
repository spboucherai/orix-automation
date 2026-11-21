#!/usr/bin/env bash
# =============================================================================
#                  SP BOUCHER | INFRASTRUCTURE & AUTOMATION
#             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
# =============================================================================
#
# Project          : ORIX OS Automation
# File             : Scripts/release/notarize.sh
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

# ORIX OS Automation
# File: Scripts/release/notarize.sh
# Description: Submits an artifact (.app, .dmg or .zip) to Apple's notary service with an EXISTING keychain profile, waits for the verdict and staples on acceptance.
#
# Author: Simon-Pierre Boucher
# Contact: contact@spboucher.ai
#   Scripts/notarize.sh <artifact> <name>
#   NOTARY_PROFILE  keychain profile created earlier with `xcrun notarytool store-credentials` (default: MacLustr-Notarize).
# This script never creates, prints or changes credentials. "notarized" is printed only when Apple answered Accepted.
set -euo pipefail
cd "$(dirname "$0")/../.."
PROFILE="${NOTARY_PROFILE:-MacLustr-Notarize}"
ARTIFACT="$1"; NAME="$2"
mkdir -p build/notary
SUBMIT="$ARTIFACT"
if [[ -d "$ARTIFACT" ]]; then
  SUBMIT="build/notary/$NAME-submit.zip"; rm -f "$SUBMIT"
  ditto -c -k --keepParent "$ARTIFACT" "$SUBMIT"
fi
OUT="build/notary/$NAME.json"
if ! xcrun notarytool submit "$SUBMIT" --keychain-profile "$PROFILE" --wait --output-format json >"$OUT" 2>"$OUT.err"; then
  echo "Notary service refused the submission of $ARTIFACT:" >&2; sed 's/^/  /' "$OUT.err" | head -8 >&2; exit 2
fi
STATUS="$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("status",""))' "$OUT")"
ID="$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("id",""))' "$OUT")"
echo "Submission $ID: $STATUS"
xcrun notarytool log "$ID" --keychain-profile "$PROFILE" "build/notary/$NAME-log.json" >/dev/null 2>&1 || true
if [[ "$STATUS" != "Accepted" ]]; then
  echo "RESULT: $ARTIFACT is NOT notarized. See build/notary/$NAME-log.json" >&2; exit 3
fi
if [[ "$ARTIFACT" != *.zip ]]; then
  xcrun stapler staple "$ARTIFACT" >/dev/null
  xcrun stapler validate "$ARTIFACT"
fi
echo "RESULT: $ARTIFACT is notarized by Apple (submission $ID)."
