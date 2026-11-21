#!/usr/bin/env bash
# ORIX OS Automation
# File: Scripts/check-headers.sh
# Description: Fails when a first-party source file lacks the author header.
#
# Author: Simon-Pierre Boucher
# Contact: contact@spboucher.ai
set -uo pipefail
cd "$(dirname "$0")/.."
MISSING=0
while IFS= read -r -d '' f; do
  if ! head -12 "$f" | grep -q "Author: Simon-Pierre Boucher"; then echo "missing header: $f"; MISSING=1; fi
done < <(git ls-files -z -- '*.swift' '*.sh' '*.py' 'project.yml')
[[ $MISSING -eq 0 ]] && echo "headers: ok" || exit 1
