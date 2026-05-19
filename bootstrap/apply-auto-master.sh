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
LOCK=/var/run/hither-bootstrap.lock

# --- Hold lock for the duration of this run. macOS doesn't ship flock(1),
# --- so use mkdir(1) as an atomic-create primitive: mkdir on an existing
# --- dir returns non-zero, making it a portable mutex.
#
# --- Stale-lock TTL: if the lock dir is older than LOCK_TTL_SEC (300s =
#     5 min), assume the prior holder was SIGKILL'd (no EXIT-trap cleanup ran)
#     and break the lock. Our work — text edits + automount -cv — completes in
#     well under 5 seconds, so a 5-minute lock is unambiguously stale.
LOCK_TTL_SEC=300
if [[ -d "${LOCK}" ]]; then
  # stat -f %m on macOS = mtime as epoch seconds; on Linux, use stat -c %Y.
  # This script is macOS-only, but the form is documented for portability.
  lock_mtime=$(stat -f %m "${LOCK}" 2>/dev/null || echo 0)
  now_epoch=$(date +%s)
  age=$(( now_epoch - lock_mtime ))
  if (( age > LOCK_TTL_SEC )); then
    echo "[warn] stale lock ${LOCK} (${age}s old > ${LOCK_TTL_SEC}s TTL) — breaking"
    rmdir "${LOCK}" 2>/dev/null || true
  fi
fi

LOCK_HELD=0
for _ in 1 2 3 4 5; do
  if mkdir "${LOCK}" 2>/dev/null; then
    LOCK_HELD=1
    trap 'rmdir "${LOCK}" 2>/dev/null || true' EXIT
    break
  fi
  sleep 1
done
if [[ "$LOCK_HELD" -ne 1 ]]; then
  echo "ERROR: failed to acquire ${LOCK} after 5s — another bootstrap in progress?" >&2
  exit 5
fi

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
