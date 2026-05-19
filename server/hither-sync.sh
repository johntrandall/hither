#!/bin/zsh
# hither-sync — keep /etc/hither_<nas> current with shares the target
# DSM user can read, on each managed Mac.
#
# Companion to: admin-technical/conventions/synology-smb-and-mac-mount-strategy.md
# Architecture: admin-technical/conventions/synology-smb-and-mac-mount-architecture.mermaid
#
# Where this runs:
#   - Each Mac's xysat worker runs this locally (per ADR-061 model).
#   - Conductor on Umbridge schedules; it does NOT execute. The work — DSM
#     API call → /etc/hither_<nas> rewrite → automount reload — is local
#     to the consuming Mac.
#
# Per-host wrapper passes via env:
#   TARGET_USER   DSM user whose visible-share-list we mirror (e.g., johntrandall).
#   NAS_LIST      Space-separated NAS hostnames to sync (e.g., "umbridge").
#                 (One /etc/hither_<nas> file per entry.)
#   NAS_PROTO     "http" or "https" for DSM Web API. Default: "http".
#                 (LAN trust; flip to https when Tailscale-tunneled.)
#
# DSM credentials: env-var-first per the chosen credential architecture
# (projects/service-credential-management/README.md, pivot 2026-05-05).
# In production, xyOps injects per-NAS env vars from xyOps Secrets:
#   <NAS_UPPER>_DSM_PASSWORD   e.g. UMBRIDGE_DSM_PASSWORD
# Fallback for manual / dev invocation: `op item get` against the
# canonical 1Password title "<NAS> - DSM - <TARGET_USER> (Login)" in
# vault "JRVIS Infra". The xysat run-as user (infra-agent) typically
# has no 1P session, so the env-var path is the load-bearing one.
#
# Calling DSM AS the target user lets the server filter the share
# list to exactly what that user can read — no admin API + per-share
# ACL inspection needed.
#
# Sudo prerequisites (per Mac, in /etc/sudoers.d/xysat-hither-sync):
#   infra-agent ALL=(root) NOPASSWD: /usr/local/sbin/hither-write-map ^[a-z0-9-]+$
# (Single grant — the wrapper validates ${host}, atomically writes /etc/hither_{host},
#  and runs automount -cv internally. Closes the path-traversal vulnerability of
#  the prior `tee /etc/auto_smb_*` wildcard grant.)
#
# Idempotent. Safe to re-run. No-op when nothing changed.

set -uo pipefail

export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/bin:/bin:/usr/sbin:/sbin"

TARGET_USER="${TARGET_USER:-johntrandall}"
NAS_LIST="${NAS_LIST:-umbridge}"
NAS_PROTO="${NAS_PROTO:-http}"
OP_VAULT="${OP_VAULT:-JRVIS Infra}"

LOG_DIR="${HOME}/Library/Logs"
LOG_FILE="${LOG_DIR}/hither-sync.log"
mkdir -p "${LOG_DIR}"

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" | tee -a "${LOG_FILE}" >&2
}

die() { log "FATAL: $*"; exit 1; }

# Required external tools. `op` is only required for the fallback credential
# path (manual / dev invocation); env-var-first runtime path doesn't need it.
for cmd in curl jq sudo; do
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
  #   1. ${<NAS_UPPER>_DSM_PASSWORD}   ← xyOps Secret injection (runtime path)
  #   2. ${DSM_PASSWORD}                ← single-NAS convenience override
  #   3. `op item get` from 1Password   ← manual / dev fallback only
  local nas="$1"
  local password=""
  local nas_upper
  nas_upper=$(printf '%s' "$nas" | tr '[:lower:]-' '[:upper:]_')
  local env_var_name="${nas_upper}_DSM_PASSWORD"
  # zsh: ${(P)var} is parameter-name expansion; bash equivalent is ${!var}.
  # Use eval to stay portable across zsh (script's shebang) and any bash callers.
  eval "password=\${${env_var_name}:-}"
  if [[ -z "$password" ]]; then
    password="${DSM_PASSWORD:-}"
  fi
  if [[ -z "$password" ]]; then
    if ! command -v op >/dev/null; then
      log "  no credential available: \$${env_var_name} unset, \$DSM_PASSWORD unset, and 'op' CLI missing"
      return 1
    fi
    password=$(op item get "${nas} - DSM - ${TARGET_USER} (Login)" \
                  --vault "${OP_VAULT}" --fields password --reveal 2>/dev/null) \
      || { log "  no credential: \$${env_var_name} unset AND op item get failed for '${nas} - DSM - ${TARGET_USER} (Login)' (likely no 1P session for run-as user)"; return 1; }
  fi
  if [[ -z "$password" ]]; then
    log "  empty DSM password — env-var and op both yielded blank"
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
  # cause us to exclude everything. Verified failure mode 2026-05-12.
  # The original 2026-05-07 filter was architecturally incompatible with
  # the deployment doc's stated design ("calling AS the target user lets
  # the DSM server filter the share list — no admin API needed").
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
  printf '# MANAGED BY xyOps hither-sync — DO NOT EDIT BY HAND.\n'
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
  # Diffs against /etc/hither_<nas>; if changed, sudo-writes + reloads.
  local nas="$1"
  local map_path="/etc/hither_${nas}"
  local desired_body
  desired_body=$(cat)

  local current_body=""
  [[ -f "${map_path}" ]] && current_body=$(< "${map_path}")

  # Strip the "Generated:" line on both sides so timestamp churn doesn't
  # cause every run to count as a diff.
  local d_normalized c_normalized
  d_normalized=$(printf '%s\n' "${desired_body}" | grep -v '^# Generated:')
  c_normalized=$(printf '%s\n' "${current_body}" | grep -v '^# Generated:')

  if [[ "${d_normalized}" == "${c_normalized}" ]]; then
    log "  no change for ${map_path} — skipping write"
    return 0
  fi

  log "  diff detected for ${map_path} — applying via hither-write-map wrapper"
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
