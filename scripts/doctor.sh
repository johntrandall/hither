#!/bin/bash
# SPDX-License-Identifier: MIT
# scripts/doctor.sh
#
# Checks Hither health on this Mac. Run as the user who will actually
# use the mounts (must have the SMB Keychain entry), NOT as root.

set -uo pipefail

EXIT=0
ok()   { echo "[ ok ] $*"; }
warn() { echo "[warn] $*"; EXIT=1; }
fail() { echo "[fail] $*"; EXIT=2; }

echo "=== Hither doctor ==="

# --- 1. Synthetic root present ---
if [[ -d /Hither ]]; then
  ok "/Hither synthetic root exists"
else
  fail "/Hither not present — run: sudo \$(which hither) bootstrap"
fi

# --- 2. auto_master has /Hither entries ---
if grep -qE '^/Hither/' /etc/auto_master 2>/dev/null; then
  ok "/etc/auto_master has /Hither entries"
else
  fail "/etc/auto_master missing /Hither entries"
fi

# --- 3. LaunchDaemon loaded ---
if sudo -n launchctl print system/com.johnrandall.hither.bootstrap >/dev/null 2>&1; then
  ok "LaunchDaemon com.johnrandall.hither.bootstrap loaded"
elif launchctl print system/com.johnrandall.hither.bootstrap >/dev/null 2>&1; then
  ok "LaunchDaemon com.johnrandall.hither.bootstrap loaded"
else
  warn "Cannot confirm LaunchDaemon state (may need sudo)"
fi

# --- 4. Wrapper script present + executable ---
if [[ -x /usr/local/sbin/hither-write-map ]]; then
  ok "/usr/local/sbin/hither-write-map present"
else
  fail "/usr/local/sbin/hither-write-map missing"
fi

# --- 5. For each subscribed host: probe shares with timeout ---
# (For v1, the host list is hardcoded as umbridge; v2 reads config.)
for host in umbridge; do
  echo "--- Probing /Hither/${host}/ ---"

  if [[ ! -d "/Hither/${host}" ]]; then
    fail "/Hither/${host} missing — autofs map not loaded?"
    continue
  fi

  # List shares (this does NOT trigger mounts; just enumerates the indirect map)
  shares=$(ls "/Hither/${host}/" 2>/dev/null || true)
  if [[ -z "${shares}" ]]; then
    warn "/Hither/${host}/ enumerates zero shares — map empty?"
    continue
  fi

  ok "/Hither/${host}/ has $(echo "${shares}" | wc -l | tr -d ' ') share entries"

  # Pick the first share and try a bounded probe-mount
  first_share=$(echo "${shares}" | head -1)
  share_path="/Hither/${host}/${first_share}"
  echo "  Probing ${share_path} (timeout 10s)..."

  # Trigger mount + try to read first regular file (don't hardcode a known-file name)
  if timeout 10 ls -1 "${share_path}/" >/dev/null 2>&1; then
    ok "${share_path} mounts cleanly"

    # TM exclusion check
    if tmutil isexcluded "${share_path}" 2>/dev/null | grep -q '\[Excluded\]'; then
      ok "${share_path} excluded from Time Machine"
    else
      warn "${share_path} not excluded from Time Machine (autofs should auto-exclude; investigate if persistent)"
    fi
  else
    fail "${share_path} did not mount within 10s (Keychain? Network? Permissions?)"
  fi
done

# --- 6. Keychain entry for SMB ---
if security find-internet-password -s umbridge -a johntrandall >/dev/null 2>&1; then
  ok "Keychain entry for //johntrandall@umbridge present"
else
  warn "Keychain missing entry //johntrandall@umbridge — prime via Finder Cmd-K"
fi

echo "=== doctor done (exit ${EXIT}) ==="
exit ${EXIT}
