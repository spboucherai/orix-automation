#!/usr/bin/env bash
# ORIX OS Automation
# File: Scripts/test/with-dev-keys.sh
# Description: Developer-only credential broker. Runs a command with the SP Chat development provider keys injected into ITS environment only; never prints, copies or stores them.
#
# Author: Simon-Pierre Boucher
# Contact: contact@spboucher.ai
#   Scripts/test/with-dev-keys.sh --check            # report which keys are present (names and lengths only)
#   Scripts/test/with-dev-keys.sh <command> [args…]  # run a command with ORIX_DEV_*_API_KEY set
# Source of the keys: the operator's existing secrets file for the SP Chat deployment, outside this repository
# (override with ORIX_DEV_SECRETS_FILE). The file is read line by line; values go straight to the child's environment.
set -euo pipefail
FILE="${ORIX_DEV_SECRETS_FILE:-$HOME/Desktop/Cluster/secrets/chat-spboucher-ai.env}"
[[ -r "$FILE" ]] || { echo "with-dev-keys: secrets file not readable (set ORIX_DEV_SECRETS_FILE). Live provider tests will be skipped." >&2; exit 78; }
read_key() { # $1 = variable name in the file
  local line; line="$(grep -E "^(export[[:space:]]+)?$1=" "$FILE" | tail -1 || true)"
  line="${line#export }"; line="${line#*=}"; line="${line%\"}"; line="${line#\"}"; line="${line%\'}"; line="${line#\'}"
  printf '%s' "$line"
}
A="$(read_key ANTHROPIC_API_KEY)"; O="$(read_key OPENAI_API_KEY)"; R="$(read_key OPENROUTER_API_KEY)"
if [[ "${1:-}" == "--check" ]]; then
  for pair in "ANTHROPIC:${#A}" "OPENAI:${#O}" "OPENROUTER:${#R}"; do
    name="${pair%%:*}"; len="${pair##*:}"
    if [[ "$len" -gt 0 ]]; then echo "$name: present (length $len)"; else echo "$name: MISSING"; fi
  done
  exit 0
fi
[[ $# -gt 0 ]] || { echo "usage: $0 --check | <command> [args…]" >&2; exit 2; }
ORIX_DEV_ANTHROPIC_API_KEY="$A" ORIX_DEV_OPENAI_API_KEY="$O" ORIX_DEV_OPENROUTER_API_KEY="$R" exec "$@"
