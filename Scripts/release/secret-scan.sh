#!/usr/bin/env bash
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
if git ls-files -z | xargs -0 grep -nIE "$PATTERN" 2>/dev/null | grep -v "Scripts/release/secret-scan.sh" | cut -c1-120; then echo "FAIL: credential-shaped string in the repository"; FAIL=1; else echo "ok"; fi
echo "== git history"
if git log -p --all 2>/dev/null | grep -nE "^\+.*($PATTERN)" | grep -v "PATTERN=" | cut -c1-120 | head -5 | grep -q .; then echo "FAIL: credential-shaped string in git history"; FAIL=1; else echo "ok"; fi
APP="${1:-}"
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
