#!/usr/bin/env bash
# =============================================================================
#                  SP BOUCHER | INFRASTRUCTURE & AUTOMATION
#             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
# =============================================================================
#
# Project          : ORIX OS Automation
# File             : Scripts/screenshots.sh
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
# File: Scripts/screenshots.sh
# Description: Photographs the real running app, one section per launch, into docs/screenshots/. Uses the app's own window id with screencapture, so the picture is what is on screen.
#
# Author: Simon-Pierre Boucher
# Contact: contact@spboucher.ai
#   Scripts/screenshots.sh <data-dir> [section…]      (needs Screen Recording for the terminal running it)
set -euo pipefail
cd "$(dirname "$0")/.."
APP="build/dd/Build/Products/Debug/ORIX OS Automation.app/Contents/MacOS/ORIX OS Automation"
DATA="$1"; shift
SECTIONS=("$@"); [[ ${#SECTIONS[@]} -gt 0 ]] || SECTIONS=(dashboard chat workflows code runs scheduler agents skills learn permissions settings)
OUT="${ORIX_SHOT_DIR:-docs/screenshots}"; mkdir -p "$OUT"
for s in "${SECTIONS[@]}"; do
  LOG="$(mktemp)"
  "$APP" -ORIXDataDir "$DATA" -ORIXSkipOnboarding YES -ORIXUITest YES -ORIXSection "$s" -ORIXShot /dev/null -ORIXShotDelay "${ORIX_SHOT_DELAY:-4}" \
    -ORIXShotHold 3 -ORIXWindowSize "${ORIX_SHOT_SIZE:-1320x840}" -AppleLanguages "(${ORIX_SHOT_LANG:-en})" -AppleLocale "${ORIX_SHOT_LOCALE:-en_US}" \
    -ORIXAppearance "${ORIX_SHOT_STYLE:-dark}" -ApplePersistenceIgnoreState YES >"$LOG" 2>/dev/null &
  PID=$!
  ID=""
  for _ in $(seq 1 100); do ID="$(sed -n 's/^ORIX_WINDOW_ID //p' "$LOG" | head -1)"; [[ -n "$ID" ]] && break; sleep 0.2; done
  if [[ -n "$ID" ]]; then sleep 0.6; screencapture -x -o -l "$ID" "$OUT/$s${ORIX_SHOT_SUFFIX:-}.png" && echo "wrote $OUT/$s${ORIX_SHOT_SUFFIX:-}.png"; else echo "no window for $s" >&2; fi
  wait $PID 2>/dev/null || true
  rm -f "$LOG"
done
