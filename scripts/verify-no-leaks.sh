#!/bin/bash
# SPDX-License-Identifier: MIT
# scripts/verify-no-leaks.sh [<path>]
#
# Pre-commit privacy gate. Reads regex alternation groups from
# ~/.config/hither/leak-patterns.txt (gitignored; outside the repo)
# and scans the given path for any match.
#
# Returns 0 only if zero matches found across all patterns.
#
# Missing-patterns-file behavior:
#   - Default (local-dev): exit 2 with a setup hint. The gate is load-bearing
#     and a missing patterns file means the privacy check silently doesn't
#     happen — a fail-open mode we shouldn't ship by default.
#   - CI / sandboxed-run mode: set HITHER_LEAK_PATTERNS_OPTIONAL=1 to opt
#     out. Used by CI environments where the patterns file isn't installed
#     because there's nothing private to leak (clean checkout, no $HOME state).

set -euo pipefail

SCAN_PATH="${1:-${HITHER_ROOT:-$(pwd)}}"
PATTERNS_FILE="${HOME}/.config/hither/leak-patterns.txt"

if [[ ! -f "${PATTERNS_FILE}" ]]; then
  if [[ "${HITHER_LEAK_PATTERNS_OPTIONAL:-0}" == "1" ]]; then
    echo "[skip] ${PATTERNS_FILE} not present — HITHER_LEAK_PATTERNS_OPTIONAL=1 set, exiting 0"
    exit 0
  fi
  echo "[FAIL] ${PATTERNS_FILE} not present — privacy gate not configured" >&2
  echo "       Local-dev setup: create the file with one regex pattern per line." >&2
  echo "       Example: 'echo \"alice|bob|family-share-name\" > ${PATTERNS_FILE}'" >&2
  echo "       CI / opt-out: re-run with HITHER_LEAK_PATTERNS_OPTIONAL=1" >&2
  exit 2
fi

echo "[scan] ${SCAN_PATH} against $(grep -cv '^\s*\(#\|$\)' "${PATTERNS_FILE}") patterns"

# Combine non-comment, non-blank lines into one big alternation
patterns=$(grep -v '^\s*\(#\|$\)' "${PATTERNS_FILE}" | paste -sd '|' -)

if [[ -z "${patterns}" ]]; then
  echo "[skip] patterns file is empty after filtering comments"
  exit 0
fi

# Exclude .git, backup dirs, and server/ from scan.
# server/ holds live deployment config (real xyOps server_ids, real 1P vault names,
# real Tailscale FQDNs) that the manifest and registration script need to function.
# These are intentional private-repo artifacts; v2 public-release sanitization will
# template them. The gate's job is to catch UNINTENTIONAL leaks into docs/, bin/,
# scripts/, bootstrap/ — not to lecture the operational config.
hits=$(grep -rEl --exclude-dir=.git --exclude-dir='*.pre-*' --exclude-dir=server "${patterns}" "${SCAN_PATH}" 2>/dev/null || true)

if [[ -n "${hits}" ]]; then
  echo "[FAIL] privacy patterns matched in:"
  echo "${hits}" | sed 's/^/  /'
  echo
  echo "Inspect with: grep -nE \"\$(grep -v '^\\s*\\(#\\|\$\\)' ${PATTERNS_FILE} | paste -sd '|' -)\" <file>"
  exit 1
fi

echo "[OK] no leak patterns matched"
exit 0
