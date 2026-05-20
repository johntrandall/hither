#!/bin/zsh
# hither-sync — keep /etc/hither_<nas> current with the shares the target
# DSM user can read.
#
# This script runs locally on each Mac. It is invoked by:
#   - The hither.sync LaunchAgent (daily fire, user GUI context).
#   - `hither sync` (manual fire from a user shell).
#
# There is no Hither server. The DSM API call, map rendering, and
# write-via-root-wrapper all happen on the consuming Mac itself, against
# the NAS over the LAN (or Tailscale if you've routed it that way).
#
# Environment:
#   TARGET_USER   DSM user whose visible-share-list we mirror.
#   NAS_LIST      Space-separated NAS hostnames to sync.
#                 One /etc/hither_<nas> file is written per entry.
#   NAS_PROTO     "http" or "https" for DSM Web API. Default: "http".
#                 (LAN trust; flip to https when tunneled.)
#
# The LaunchAgent's plist sets these env vars from the user's
# subscription set; `hither sync` injects them per-invocation. On a
# fresh install with no subscriptions yet, the script falls back to the
# placeholder defaults below and exits 1 because the placeholder DSM
# host isn't reachable — that's the expected signal to run
# `hither subscribe`.
#
# DSM credential resolution:
#   1. Env var ${NAS_UPPER}_DSM_PASSWORD (e.g. for a NAS subscribed as
#      "mynas", the var is MYNAS_DSM_PASSWORD).
#      Lets the operator override out-of-band — e.g.
#      `MYNAS_DSM_PASSWORD=$(op read ...) hither sync`.
#   2. macOS Keychain via
#      `security find-internet-password -s <nas> -a <TARGET_USER> -w`.
#      This is the load-bearing path: the LaunchAgent runs in user GUI
#      context, which has Keychain access, and uses the same Keychain
#      entry that Finder Cmd-K populates for the SMB mount itself.
#
# No 1Password dependency. Users who keep DSM passwords in 1Password
# can inject via env-var override at invocation time.
#
# Calling DSM AS the target user lets the server filter the share list
# to exactly what that user can read — no admin API + per-share ACL
# inspection needed.
#
# Sudo prerequisites (per Mac, in /etc/sudoers.d/hither-write-map):
#   %admin ALL=(root) NOPASSWD: /usr/local/sbin/hither-write-map ^[a-z0-9-]+$
# Single grant — the wrapper validates ${host}, atomically writes
# /etc/hither_{host}, and runs automount -cv internally.
#
# Idempotent. Safe to re-run. No-op when nothing changed.

set -uo pipefail

export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/bin:/bin:/usr/sbin:/sbin"

# Placeholder defaults — overwritten by the LaunchAgent's env block (which
# is rendered from the user's subscription set at `hither subscribe` time)
# and by `hither sync`'s per-invocation env injection. Fresh installs with
# no subscriptions will hit these and fail to resolve, which is the
# intentional signal to run `hither subscribe <nas> --user <dsm-user>`.
TARGET_USER="${TARGET_USER:-PLACEHOLDER_USER}"
NAS_LIST="${NAS_LIST:-PLACEHOLDER_NAS}"
NAS_PROTO="${NAS_PROTO:-http}"

LOG_DIR="${HOME}/Library/Logs/hither"
LOG_FILE="${LOG_DIR}/sync.log"
mkdir -p "${LOG_DIR}"

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" | tee -a "${LOG_FILE}" >&2
}

die() { log "FATAL: $*"; exit 1; }

# Required external tools.
for cmd in curl jq sudo security; do
  command -v "$cmd" >/dev/null || die "missing required tool: $cmd"
done

# ---------------------------------------------------------------------------
# DSM API helpers
# ---------------------------------------------------------------------------

dsm_login() {
  # Args: <nas-host>
  # Returns SID on stdout (single line), or non-zero on failure.
  #
  # Credential resolution order:
  #   1. ${<NAS_UPPER>_DSM_PASSWORD}   ← env-var override (manual / scripted)
  #   2. macOS Keychain (security find-internet-password)  ← LaunchAgent path
  local nas="$1"
  local password=""
  local nas_upper
  nas_upper=$(printf '%s' "$nas" | tr '[:lower:]-' '[:upper:]_')
  local env_var_name="${nas_upper}_DSM_PASSWORD"
  # zsh: ${(P)var} is parameter-name expansion; bash equivalent is ${!var}.
  # Use eval to stay portable across zsh (script's shebang) and any bash callers.
  eval "password=\${${env_var_name}:-}"
  if [[ -z "$password" ]]; then
    # Keychain lookup. `security find-internet-password -w` prints just the
    # password to stdout on success, nothing on failure. The -s/-a tuple
    # matches the same Keychain entry Finder Cmd-K uses for SMB:
    #   security add-internet-password -s <nas> -a <user> -r 'smb ' -w <pass>
    # (Finder may also write protocol 'afp '/'cifs'; we don't filter by -r
    # so any matching server+account pair is acceptable.)
    password=$(security find-internet-password -s "${nas}" -a "${TARGET_USER}" -w 2>/dev/null) \
      || { log "  no credential: \$${env_var_name} unset AND no Keychain entry for ${TARGET_USER}@${nas} (try 'security add-internet-password' or prime via Finder Cmd-K)"; return 1; }
  fi
  if [[ -z "$password" ]]; then
    log "  empty DSM password — env-var and Keychain both yielded blank"
    return 1
  fi

  local resp
  resp=$(curl -sS --max-time 10 \
    "${NAS_PROTO}://${nas}:5000/webapi/auth.cgi" \
    --data-urlencode "api=SYNO.API.Auth" \
    --data-urlencode "version=6" \
    --data-urlencode "method=login" \
    --data-urlencode "account=${TARGET_USER}" \
    --data-urlencode "passwd=${password}" \
    --data-urlencode "format=sid") || return 1

  local ok sid
  ok=$(echo "${resp}" | jq -r '.success // false')
  [[ "${ok}" == "true" ]] || { log "  DSM auth failed: $(echo "$resp" | jq -c '.error // empty')"; return 1; }
  sid=$(echo "${resp}" | jq -r '.data.sid')
  printf '%s\n' "${sid}"
}

dsm_logout() {
  # Args: <nas-host> <sid>
  local nas="$1" sid="$2"
  curl -sS --max-time 10 \
    "${NAS_PROTO}://${nas}:5000/webapi/auth.cgi?api=SYNO.API.Auth&version=6&method=logout&_sid=${sid}" \
    >/dev/null 2>&1 || true
}

dsm_list_smb_readable_shares() {
  # Args: <nas-host> <sid>
  # Returns share names (one per line) the authenticated user can READ via SMB.
  #
  # Approach: SYNO.FileStation.List/list_share, called WITH the user's own SID,
  # returns shares filtered by the server-side ACL for that user. We trust
  # that filter directly — it's the canonical "what shares does this user
  # see" answer the DSM server gives File Station and Finder.
  #
  # Why not the SYNO.Core.Share.Permission per-share double-check?
  # That API requires admin privilege. Calling it as a non-admin user
  # (which is the design — we call AS the target user, by intent) returns
  # error code 105 (insufficient privilege) for every share, which would
  # cause us to exclude everything.
  #
  # Edge case: FileStation visibility CAN occasionally exceed SMB-mount
  # access — a share may appear here yet fail mount_smbfs with NT-status
  # 0xC00001A5. autofs handles those gracefully by logging at mount time;
  # they don't crash the overall map. If a particular share is a persistent
  # offender, exclude it via /etc/auto_master rather than at this layer.
  local nas="$1" sid="$2"
  curl -sS --max-time 30 \
    "${NAS_PROTO}://${nas}:5000/webapi/entry.cgi" \
    --data-urlencode "api=SYNO.FileStation.List" \
    --data-urlencode "version=2" \
    --data-urlencode "method=list_share" \
    --data-urlencode "_sid=${sid}" \
    | jq -r '.data.shares[]?.name' \
    | sort
}

# ---------------------------------------------------------------------------
# Map rendering
# ---------------------------------------------------------------------------

render_map() {
  # Args: <nas-host>
  # Reads share names on stdin, emits an /etc/hither_<nas> file body.
  local nas="$1"
  printf '# /etc/hither_%s — AutoFS indirect map.\n' "${nas}"
  printf '# MANAGED BY hither sync — DO NOT EDIT BY HAND.\n'
  printf '# Generated: %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')"
  printf '# Target user: %s\n' "${TARGET_USER}"
  printf '# Format: <share-key>  -fstype=smbfs,soft  ://<user>@<host>/<share>\n'
  printf '\n'
  while IFS= read -r share; do
    [[ -z "${share}" ]] && continue
    printf '%-50s -fstype=smbfs,soft ://%s@%s/%s\n' \
      "${share}" "${TARGET_USER}" "${nas}" "${share}"
  done
}

apply_map_if_changed() {
  # Args: <nas-host>  (reads desired body on stdin)
  # Diffs against /etc/hither_<nas>; if changed (or if a needs-reload marker
  # is present from a prior failed automount), sudo-writes + reloads.
  local nas="$1"
  local map_path="/etc/hither_${nas}"
  local marker_path="/etc/hither_${nas}.needs-reload"
  local desired_body
  desired_body=$(cat)

  local current_body=""
  [[ -f "${map_path}" ]] && current_body=$(< "${map_path}")

  # Strip the "Generated:" line on both sides so timestamp churn doesn't
  # cause every run to count as a diff.
  local d_normalized c_normalized
  d_normalized=$(printf '%s\n' "${desired_body}" | grep -v '^# Generated:')
  c_normalized=$(printf '%s\n' "${current_body}" | grep -v '^# Generated:')

  # If a marker is present, the prior wrapper wrote the map but the autofs
  # reload failed — re-invoke unconditionally so the wrapper retries the
  # `automount -cv`. The wrapper clears the marker on success.
  if [[ ! -f "${marker_path}" && "${d_normalized}" == "${c_normalized}" ]]; then
    log "  no change for ${map_path} — skipping write"
    return 0
  fi

  if [[ -f "${marker_path}" ]]; then
    log "  ${marker_path} present (prior automount -cv failure) — forcing retry via wrapper"
  else
    log "  diff detected for ${map_path} — applying via hither-write-map wrapper"
  fi
  printf '%s\n' "${desired_body}" \
    | sudo -n /usr/local/sbin/hither-write-map "${nas}" >/dev/null \
    || { log "  hither-write-map failed (wrapper handles both tee + automount -cv atomically)"; return 1; }

  log "  ${map_path} updated; automount -cv invoked by wrapper"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

log "hither-sync start (target_user=${TARGET_USER}, nas_list='${NAS_LIST}')"

exit_code=0
for nas in ${(z)NAS_LIST}; do
  log "processing ${nas}"
  if ! sid=$(dsm_login "${nas}"); then
    log "  skipping ${nas} (auth failed)"
    exit_code=1
    continue
  fi

  # `defer` style: ensure logout regardless of subsequent failures.
  {
    if ! shares=$(dsm_list_smb_readable_shares "${nas}" "${sid}"); then
      log "  list_share failed for ${nas}"
      exit_code=1
    elif [[ -z "${shares}" ]]; then
      log "  list_share returned no visible shares for ${nas} — refusing to write empty map"
      exit_code=1
    else
      share_count=$(printf '%s\n' "${shares}" | wc -l | tr -d ' ')
      log "  ${share_count} visible shares"
      printf '%s\n' "${shares}" \
        | render_map "${nas}" \
        | apply_map_if_changed "${nas}" \
        || exit_code=1
    fi
  } always {
    dsm_logout "${nas}" "${sid}"
  }
done

log "hither-sync done (exit ${exit_code})"
exit "${exit_code}"
