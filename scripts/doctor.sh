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

# --- 3. LaunchDaemon (revert defender) loaded ---
if sudo -n launchctl print system/com.johnrandall.hither.bootstrap >/dev/null 2>&1; then
  ok "LaunchDaemon com.johnrandall.hither.bootstrap loaded"
elif launchctl print system/com.johnrandall.hither.bootstrap >/dev/null 2>&1; then
  ok "LaunchDaemon com.johnrandall.hither.bootstrap loaded"
else
  warn "Cannot confirm LaunchDaemon state (may need sudo)"
fi

# --- 3b. LaunchAgent (daily sync) loaded ---
# Runs in user GUI context — no sudo needed to query.
if launchctl print "gui/$(id -u)/com.johnrandall.hither.sync" >/dev/null 2>&1; then
  ok "LaunchAgent com.johnrandall.hither.sync loaded"
else
  warn "LaunchAgent com.johnrandall.hither.sync not loaded — run: hither bootstrap --user-only"
fi

# --- 3c. Installed sync script present + executable ---
if [[ -x /usr/local/libexec/hither/hither-sync.sh ]]; then
  ok "/usr/local/libexec/hither/hither-sync.sh present"
else
  fail "/usr/local/libexec/hither/hither-sync.sh missing — run: sudo \$(which hither) bootstrap"
fi

# --- 4. Wrapper script present + executable ---
if [[ -x /usr/local/sbin/hither-write-map ]]; then
  ok "/usr/local/sbin/hither-write-map present"
else
  fail "/usr/local/sbin/hither-write-map missing"
fi

# --- 5. For each subscribed host: probe shares with timeout ---
# Subscriptions live at ~/.config/hither/subscriptions/<nas>.toml. Fall
# back to whatever indirect maps are present in /etc/hither_* if no
# subscriptions exist yet (catches operator-installed configs).
hosts=""
if [[ -d "${HOME}/.config/hither/subscriptions" ]]; then
  hosts=$(find "${HOME}/.config/hither/subscriptions" -name '*.toml' -maxdepth 1 \
    -exec basename {} .toml \; 2>/dev/null | sort)
fi
if [[ -z "${hosts}" ]]; then
  hosts=$(find /etc -maxdepth 1 -name 'hither_*' ! -name '*.needs-reload' \
    -exec basename {} \; 2>/dev/null | sed 's/^hither_//' | sort)
fi
if [[ -z "${hosts}" ]]; then
  warn "no subscriptions found — run: hither subscribe <nas> --user <dsm-user>"
  echo "=== doctor done (exit ${EXIT}) ==="
  exit ${EXIT}
fi

for host in ${hosts}; do
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

# --- 6. Keychain entry for SMB (one per subscribed host) ---
# Look up TARGET_USER from each subscription's TOML; check that the
# Keychain has a matching SMB credential for that user+host.
for host in ${hosts}; do
  sub_path="${HOME}/.config/hither/subscriptions/${host}.toml"
  if [[ ! -f "${sub_path}" ]]; then
    continue
  fi
  user=$(awk -F'=' '/^[[:space:]]*user[[:space:]]*=/ {
    sub(/^[^=]*=[[:space:]]*/, "", $0); gsub(/^"|"$/, "", $0); print; exit
  }' "${sub_path}")
  if [[ -z "${user}" ]]; then
    continue
  fi
  if security find-internet-password -s "${host}" -a "${user}" >/dev/null 2>&1; then
    ok "Keychain entry for //${user}@${host} present"
  else
    warn "Keychain missing entry //${user}@${host} — prime via Finder Cmd-K or re-subscribe"
  fi
done

echo "=== doctor done (exit ${EXIT}) ==="
exit ${EXIT}
