#!/usr/bin/env bash
# =============================================================================
#                  SP BOUCHER | INFRASTRUCTURE & AUTOMATION
#             ARTIFICIAL INTELLIGENCE • FINANCE • ENGINEERING
# =============================================================================
#
# Project          : ORIX OS Automation
# File             : Scripts/release/secret-scan.sh
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
# File: Scripts/release/secret-scan.sh
# Description: Fails when the repository or a built app contains credential-shaped strings, the development key variable names in a release binary, or internal host names.
#
# Author: Simon-Pierre Boucher
# Contact: contact@spboucher.ai
#   Scripts/release/secret-scan.sh [path-to-app]
set -uo pipefail
cd "$(dirname "$0")/../.."
FAIL=0
PATTERN='sk-ant-[A-Za-z0-9_-]{20,}|sk-or-v1-[A-Za-z0-9]{20,}|sk-(proj-)?[A-Za-z0-9_-]{32,}|xai-[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY-----|gh[pousr]_[A-Za-z0-9]{30,}'
echo "== tracked files"
# Test sources hold synthetic, key-shaped fixtures for the redactor and the provider stubs; they are covered by the
# exact-value check below instead of the shape check.
if git ls-files -z | grep -zv "/Tests/" | xargs -0 grep -nIE "$PATTERN" 2>/dev/null | grep -v "Scripts/release/secret-scan.sh" | cut -c1-120; then echo "FAIL: credential-shaped string in the repository"; FAIL=1; else echo "ok"; fi
echo "== git history"
if git log -p --all -- . ':(exclude)*/Tests/*' 2>/dev/null | grep -nE "^\+.*($PATTERN)" | grep -v "PATTERN=" | cut -c1-120 | head -5 | grep -q .; then echo "FAIL: credential-shaped string in git history"; FAIL=1; else echo "ok"; fi
APP="${1:-}"
# Exact-value check: when run under Scripts/test/with-dev-keys.sh, the real development keys are searched for (as fixed
# strings, never printed) in every tracked file, the whole git history and the built app.
REAL=0
for v in "${ORIX_DEV_ANTHROPIC_API_KEY:-}" "${ORIX_DEV_OPENAI_API_KEY:-}" "${ORIX_DEV_OPENROUTER_API_KEY:-}"; do
  [[ ${#v} -ge 20 ]] || continue
  REAL=1
  if git ls-files -z | xargs -0 grep -lIF -- "$v" >/dev/null 2>&1; then echo "FAIL: a real development key is in a tracked file"; FAIL=1; fi
  if git log -p --all 2>/dev/null | grep -qF -- "$v"; then echo "FAIL: a real development key is in git history"; FAIL=1; fi
  if [[ -n "$APP" ]] && LC_ALL=C grep -rqF -- "$v" "$APP" 2>/dev/null; then echo "FAIL: a real development key is in the app bundle"; FAIL=1; fi
done
echo "== exact development key values"
if [[ $REAL -eq 1 ]]; then [[ $FAIL -eq 0 ]] && echo "ok: none of the real keys appears in tracked files, history or the bundle"; else echo "not checked (run under Scripts/test/with-dev-keys.sh to check)"; fi
if [[ -n "$APP" ]]; then
  echo "== $APP"
  BIN="$APP/Contents/MacOS/$(/usr/libexec/PlistBuddy -c 'Print CFBundleExecutable' "$APP/Contents/Info.plist")"
  if LC_ALL=C grep -rIlE "$PATTERN" "$APP" 2>/dev/null | head -3 | grep -q .; then echo "FAIL: credential-shaped string in the bundle"; FAIL=1; fi
  if strings -a "$BIN" | grep -E "$PATTERN" | head -1 | grep -q .; then echo "FAIL: credential-shaped string in the executable"; FAIL=1; fi
  if strings -a "$BIN" | grep -q "ORIX_DEV_ANTHROPIC_API_KEY"; then echo "FAIL: development credential adapter is present in this binary"; FAIL=1; else echo "ok: no development credential adapter"; fi
  if strings -a "$BIN" | grep -iE "maclustr|spboucher\.ai/|192\.168\.|\.internal\b" | head -3 | grep -q .; then echo "FAIL: internal host name in the executable"; FAIL=1; else echo "ok: no internal host names"; fi
  if find "$APP" -name "*.env" -o -name "*.p8" -o -name "*.p12" | grep -q .; then echo "FAIL: key material file in the bundle"; FAIL=1; fi
fi
[[ $FAIL -eq 0 ]] && echo "RESULT: clean" || echo "RESULT: FAILED"
exit $FAIL
