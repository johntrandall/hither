#!/bin/bash
# SPDX-License-Identifier: MIT
# bootstrap/install-launchdaemon.sh
#
# Installs com.johnrandall.hither.bootstrap.plist at /Library/LaunchDaemons/
# and loads it. Idempotent — if already loaded, skips.

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: must be run with sudo" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
PLIST_SRC="${SCRIPT_DIR}/launchd/com.johnrandall.hither.bootstrap.plist"
PLIST_DST=/Library/LaunchDaemons/com.johnrandall.hither.bootstrap.plist
LABEL=com.johnrandall.hither.bootstrap
LOG_DIR=/var/log/hither

# --- Pre-flight ---
if [[ ! -f "${PLIST_SRC}" ]]; then
  echo "ERROR: source plist not found at ${PLIST_SRC}" >&2
  exit 2
fi

# --- Create log dir (launchd auto-creates log FILES but NOT parent dirs) ---
mkdir -p "${LOG_DIR}"
chown root:wheel "${LOG_DIR}"
chmod 755 "${LOG_DIR}"

# --- Install plist ---
install -m 644 -o root -g wheel "${PLIST_SRC}" "${PLIST_DST}"
echo "[ok] installed ${PLIST_DST}"

# --- Load if not already loaded ---
if launchctl print "system/${LABEL}" >/dev/null 2>&1; then
  echo "[skip] LaunchDaemon ${LABEL} already loaded"
else
  launchctl bootstrap system "${PLIST_DST}"
  echo "[ok] loaded LaunchDaemon ${LABEL}"
fi

exit 0
