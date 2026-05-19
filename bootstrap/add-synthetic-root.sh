#!/bin/bash
# SPDX-License-Identifier: MIT
# bootstrap/add-synthetic-root.sh
#
# Idempotently appends `Hither` to /etc/synthetic.conf, then runs
# `apfs.util -t` to materialize the synthetic root dir at /Hither
# without requiring a reboot.
#
# Per `man synthetic.conf`: a two-column `name<TAB>target` entry creates
# a synthetic SYMLINK at /<name> pointing to <target>. We use this form
# to point /Hither at /System/Volumes/Data/Hither so the synthetic root
# lives on the writable Data volume (Sealed System Volume is read-only).
# Single-column entries create empty stub directories at / which cannot
# host autofs mounts on a sealed system volume — verified broken in
# practice, hence the symlink form is the only one we ship.
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
# Two-column symlink form: name<TAB>target. /Hither -> /System/Volumes/Data/Hither
ENTRY=$'Hither\tSystem/Volumes/Data/Hither'

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
# Expected state: `Hither<TAB>System/Volumes/Data/Hither` (symlink form).
# If we see ANY `Hither<...>` line (with or without target), treat as already
# configured and skip. If a user has the legacy single-column directory form,
# we leave it (don't auto-rewrite; operator can remove + reboot if needed).
if [[ -f "${SYNTHETIC}" ]] && grep -qE "^Hither([[:space:]]|$)" "${SYNTHETIC}"; then
  if grep -qE $'^Hither\tSystem/Volumes/Data/Hither$' "${SYNTHETIC}"; then
    echo "[skip] ${SYNTHETIC} already in symlink form (correct)"
  elif grep -qE "^Hither[[:space:]]" "${SYNTHETIC}"; then
    echo "[skip] ${SYNTHETIC} has 'Hither<TAB>...' (custom symlink target); leaving as-is"
  else
    echo "[warn] ${SYNTHETIC} has legacy 'Hither' directory form; leaving as-is (manual remove + reboot to upgrade)"
  fi
else
  # Ensure file ends in newline before appending
  if [[ -f "${SYNTHETIC}" && -s "${SYNTHETIC}" ]]; then
    [[ "$(tail -c 1 "${SYNTHETIC}" | od -An -tx1 | tr -d ' ')" == "0a" ]] || printf '\n' >> "${SYNTHETIC}"
  fi
  printf '%s\n' "${ENTRY}" >> "${SYNTHETIC}"
  echo "[ok] appended symlink-form entry to ${SYNTHETIC}"
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
