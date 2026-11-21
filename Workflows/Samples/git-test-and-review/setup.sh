#!/usr/bin/env bash
# ORIX OS Automation
# File: Workflows/Samples/git-test-and-review/setup.sh
# Description: Creates the tiny sample Git repository of the "Git repository test-and-review assistant" example: two commits, then an uncommitted change that breaks one test.
#
# Author: Simon-Pierre Boucher
# Contact: contact@spboucher.ai
#
# Usage: ./setup.sh [target folder]      (default: ~/ORIX Samples/git-test-and-review)
# Creates <target>/repo. Refuses to touch an existing repo folder. No nested .git is stored in the ORIX repository:
# the sample repository only exists after this script ran.
set -euo pipefail
TARGET="${1:-$HOME/ORIX Samples/git-test-and-review}"
REPO="$TARGET/repo"
[ -e "$REPO" ] && { echo "setup: $REPO already exists; remove it first" >&2; exit 1; }
mkdir -p "$REPO"
cd "$REPO"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
git init -q -b main .
git config user.name "ORIX Sample"
git config user.email "sample@example.invalid"
git config commit.gpgsign false
export GIT_AUTHOR_DATE="2026-11-02T09:00:00Z" GIT_COMMITTER_DATE="2026-11-02T09:00:00Z"

cat > slugify.sh <<'SH'
#!/bin/sh
# slugify: lower-case words joined by dashes.
#   sh slugify.sh "Hello World"   ->   hello-world
printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -s ' ' '-'
printf '\n'
SH
cat > run-tests.sh <<'SH'
#!/bin/sh
# Tiny test runner: prints one line per case and exits 1 when any case fails. Reads only; writes nothing.
failed=0
check() {
  got="$(sh slugify.sh "$1")"
  if [ "$got" = "$2" ]; then echo "ok   - slugify '$1' -> '$got'"; else echo "FAIL - slugify '$1': expected '$2', got '$got'"; failed=1; fi
}
check "Hello World" "hello-world"
check "ORIX OS Automation" "orix-os-automation"
check "two  spaces" "two-spaces"
if [ "$failed" -eq 0 ]; then echo "3 tests passed"; else echo "tests FAILED"; fi
exit "$failed"
SH
printf '# slugify\n\nA one-line shell helper with a tiny test runner (`sh run-tests.sh`).\n' > README.md
git add -A && git commit -q -m "Add slugify helper and its tests"

export GIT_AUTHOR_DATE="2026-11-09T09:00:00Z" GIT_COMMITTER_DATE="2026-11-09T09:00:00Z"
printf '\nUsage: `sh slugify.sh "Some Title"`.\n' >> README.md
git add -A && git commit -q -m "Document the usage"

# The uncommitted change under review: underscores instead of dashes (breaks all three tests) and a README note.
cat > slugify.sh <<'SH'
#!/bin/sh
# slugify: lower-case words joined by underscores.
#   sh slugify.sh "Hello World"   ->   hello_world
printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -s ' ' '_'
printf '\n'
SH
printf '\nSeparator changed to an underscore.\n' >> README.md
printf 'scratch file, not tracked\n' > notes.tmp
echo "setup: created $REPO (2 commits on main, 2 modified files, 1 untracked file)"
