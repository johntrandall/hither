#!/bin/bash
# SPDX-License-Identifier: MIT
# bootstrap/add-synthetic-root.sh
#
# Idempotently appends `Hither` to /etc/synthetic.conf, then runs
# `apfs.util -t` to materialize the synthetic root dir at /Hither
# without requiring a reboot.
#
# Per `man synthetic.conf`: single-column entries (no second field)
# create empty directories at /. Tab-or-no-second-column required;
# trailing whitespace after `Hither` would be interpreted as a symlink
# target.
#
# apfs.util -t is an Apple-private flag (not in `man apfs.util`),
# discovered via the Nix installer pattern. Observed working on
# macOS 15.7.7. If Apple changes behavior in a future macOS, fall
# back to reboot.

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: must be run with sudo" >&2
  exit 1
fi

SYNTHETIC=/etc/synthetic.conf
APFS_UTIL=/System/Library/Filesystems/apfs.fs/Contents/Resources/apfs.util
TARGET_DIR=/Hither
ENTRY="Hither"

# --- Pre-flight: /Hither must not already exist as a non-synthetic dir ---
if [[ -e "${TARGET_DIR}" && ! -d "${TARGET_DIR}" ]]; then
  echo "ERROR: ${TARGET_DIR} exists but is not a directory" >&2
  exit 2
fi

# --- Backup synthetic.conf if present and not already backed up ---
if [[ -f "${SYNTHETIC}" ]] && ! ls "${SYNTHETIC}".pre-hither-* >/dev/null 2>&1; then
  cp "${SYNTHETIC}" "${SYNTHETIC}.pre-hither-$(date -u +%Y%m%dT%H%M%SZ)"
  echo "[ok] backup: ${SYNTHETIC}.pre-hither-*"
fi

# --- Append entry if not already present ---
# Note: we match the entire line `^Hither$` (no second column, no whitespace)
# to ensure idempotency. If somebody added `Hither\tsomething` (symlink form),
# we leave it alone and warn.
if [[ -f "${SYNTHETIC}" ]] && grep -qE "^Hither([[:space:]]|$)" "${SYNTHETIC}"; then
  if grep -qE "^Hither[[:space:]]" "${SYNTHETIC}"; then
    echo "[warn] ${SYNTHETIC} has 'Hither<TAB>...' (symlink form); leaving as-is"
  else
    echo "[skip] ${SYNTHETIC} already contains 'Hither' entry"
  fi
else
  # Ensure file ends in newline before appending
  if [[ -f "${SYNTHETIC}" && -s "${SYNTHETIC}" ]]; then
    [[ "$(tail -c 1 "${SYNTHETIC}" | od -An -tx1 | tr -d ' ')" == "0a" ]] || printf '\n' >> "${SYNTHETIC}"
  fi
  printf '%s\n' "${ENTRY}" >> "${SYNTHETIC}"
  echo "[ok] appended '${ENTRY}' to ${SYNTHETIC}"
fi

# --- Materialize via apfs.util -t (no reboot) ---
if [[ ! -x "${APFS_UTIL}" ]]; then
  echo "ERROR: ${APFS_UTIL} not found or not executable" >&2
  exit 3
fi

"${APFS_UTIL}" -t >/dev/null 2>&1 || true

# --- Verify with a brief delay (apfs.util -t may queue rather than apply synchronously) ---
sleep 1
if [[ ! -d "${TARGET_DIR}" ]]; then
  echo "ERROR: ${TARGET_DIR} not materialized after apfs.util -t" >&2
  echo "       Fallback: reboot the Mac, then re-verify." >&2
  exit 4
fi

echo "[ok] ${TARGET_DIR} synthetic root materialized"
exit 0
