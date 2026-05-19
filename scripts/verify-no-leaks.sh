#!/bin/bash
# SPDX-License-Identifier: MIT
# scripts/verify-no-leaks.sh [<path>]
#
# Pre-commit privacy gate. Reads regex alternation groups from
# ~/.config/hither/leak-patterns.txt (gitignored; outside the repo)
# and scans the given path for any match.
#
# Returns 0 only if zero matches found across all patterns.
# Returns 0 (with a setup hint) if the patterns file is missing —
# CI-friendly. Local developers must stage the patterns file.

set -euo pipefail

SCAN_PATH="${1:-${HITHER_ROOT:-$(pwd)}}"
PATTERNS_FILE="${HOME}/.config/hither/leak-patterns.txt"

if [[ ! -f "${PATTERNS_FILE}" ]]; then
  echo "[skip] ${PATTERNS_FILE} not present — CI mode (no enforcement)"
  echo "       Local developers: create with patterns to scan (see README)"
  exit 0
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
