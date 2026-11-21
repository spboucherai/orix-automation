#!/usr/bin/env bash
# ORIX OS Automation
# File: Scripts/test/test-all.sh
# Description: Runs `swift test` in every package (or the ones named) and writes docs/release/test-report.json with pass/fail counts per package.
#
# Author: Simon-Pierre Boucher
# Contact: contact@spboucher.ai
#   Scripts/test/test-all.sh [Package…]           without provider keys: live suites print SKIPPED
#   Scripts/test/with-dev-keys.sh Scripts/test/test-all.sh   with the development keys: live suites run
set -uo pipefail
cd "$(dirname "$0")/../.."
PACKAGES=("$@"); [[ ${#PACKAGES[@]} -gt 0 ]] || PACKAGES=($(ls Packages))
mkdir -p build/test-logs docs/release
ROWS=""; FAILED=0
for p in "${PACKAGES[@]}"; do
  [[ -d "Packages/$p/Tests" ]] || continue
  LOG="build/test-logs/$p.log"
  ( cd "Packages/$p" && LC_ALL=C swift test 2>&1 ) | sed $'s/\x1b\\[[0-9;]*m//g' > "$LOG"
  SUMMARY="$(grep -E "Test run with [0-9]+ tests?" "$LOG" | tail -1)"
  TESTS="$(sed -nE 's/.*Test run with ([0-9]+) tests?.*/\1/p' <<<"$SUMMARY")"; TESTS="${TESTS:-0}"
  ISSUES="$(sed -nE 's/.*with ([0-9]+) issues?.*/\1/p' <<<"$SUMMARY")"; ISSUES="${ISSUES:-0}"
  SKIPPED="$(grep -c "SKIPPED(" "$LOG" || true)"
  if grep -q "passed after" <<<"$SUMMARY"; then STATUS=passed; else STATUS=failed; FAILED=1; fi
  printf '%-26s %-7s tests=%-4s issues=%-3s skipped-notes=%s\n' "$p" "$STATUS" "$TESTS" "$ISSUES" "$SKIPPED"
  ROWS="$ROWS{\"package\":\"$p\",\"status\":\"$STATUS\",\"tests\":$TESTS,\"issues\":$ISSUES,\"skippedNotes\":$SKIPPED},"
done
LIVE=false; [[ -n "${ORIX_DEV_ANTHROPIC_API_KEY:-}" ]] && LIVE=true
printf '{"date":"%s","liveProviderKeys":%s,"macOS":"%s","packages":[%s]}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$LIVE" "$(sw_vers -productVersion)" "${ROWS%,}" > docs/release/test-report.json
echo "report: docs/release/test-report.json"
exit $FAILED
