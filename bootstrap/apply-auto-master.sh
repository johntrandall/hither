#!/bin/bash
# SPDX-License-Identifier: MIT
# bootstrap/apply-auto-master.sh <host>
#
# SCOPE GUARANTEE: this script manages ONLY lines matching ^/Hither/.
# It NEVER touches `/Network/*`, `/home`, `/-`, `/Network/Servers`, or
# any other lines. The anchored grep `^/Hither/{host}[[:space:]]` is used
# for both detection and append. This guarantee lets the LaunchDaemon
# re-run this script at boot without ever resurrecting `/Network/*`
# entries we removed during the migration.
#
# DAEMON GUARANTEE: this script NEVER stat/ls/cat anything under
# /Hither/{host}/. autofs would attempt a root-context mount which has
# no Keychain → fails. Mount verification belongs in scripts/doctor.sh,
# invoked by the user only.

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: must be run with sudo" >&2
  exit 1
fi

if [[ $# -ne 1 ]]; then
  echo "ERROR: usage: $(basename "$0") <host>" >&2
  exit 2
fi

host="$1"

# --- Validate host (same whitelist as the wrapper) ---
if [[ ! "$host" =~ ^[a-z0-9-]+$ ]]; then
  echo "ERROR: host must match ^[a-z0-9-]+$ (got: ${host})" >&2
  exit 3
fi

AUTO_MASTER=/etc/auto_master
LOCK=/var/lock/hither.lock

# --- Hold lock for the duration of this run (race with LaunchDaemon or other invocations) ---
mkdir -p "$(dirname "${LOCK}")"
exec 9>"${LOCK}"
flock -x 9

# --- Backup auto_master if not already backed up this run ---
if ! ls "${AUTO_MASTER}".pre-hither-* >/dev/null 2>&1; then
  cp "${AUTO_MASTER}" "${AUTO_MASTER}.pre-hither-$(date -u +%Y%m%dT%H%M%SZ)"
  echo "[ok] backup: ${AUTO_MASTER}.pre-hither-*"
fi

# --- Append the /Hither/{host} line if not present ---
# Anchored grep matches `^/Hither/{host}` followed by whitespace (tab or space).
# This is strict enough to be idempotent and loose enough to tolerate either
# tab or space if the file was hand-edited.
PATTERN="^/Hither/${host}[[:space:]]"
if grep -qE "${PATTERN}" "${AUTO_MASTER}"; then
  echo "[skip] /Hither/${host} entry already present in ${AUTO_MASTER}"
else
  # Ensure file ends in newline before appending
  if [[ -s "${AUTO_MASTER}" ]]; then
    [[ "$(tail -c 1 "${AUTO_MASTER}" | od -An -tx1 | tr -d ' ')" == "0a" ]] || printf '\n' >> "${AUTO_MASTER}"
  fi
  # Exact byte sequence: /Hither/{host}\t hither_{host}\t -nosuid\n  (literal TABs, no stray spaces)
  printf '/Hither/%s\thither_%s\t-nosuid\n' "${host}" "${host}" >> "${AUTO_MASTER}"
  echo "[ok] appended /Hither/${host} entry to ${AUTO_MASTER}"
fi

# --- Reload autofs maps ---
if ! /usr/sbin/automount -cv >/dev/null 2>&1; then
  echo "ERROR: appended entry but automount -cv failed" >&2
  exit 4
fi

echo "[ok] ${AUTO_MASTER} contains /Hither/${host} entry; automount reloaded"
exit 0
