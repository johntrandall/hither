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

# HITHER_NOTIFY: "1" to fire macOS user notifications when the share-set
# changes between syncs (shares added or removed). Default "0" (silent)
# preserves v0.4.x behavior. Set by hither_refresh_launchagent_env from
# the user's subscription set (notify_on_changes field), or by the CLI
# flags --notify / --no-notify in `bin/hither sync`.
HITHER_NOTIFY="${HITHER_NOTIFY:-0}"

# HITHER_NOTIFY_DRY_RUN: test-only escape hatch. When "1", the notification
# is NOT fired via osascript; instead the would-be invocation is logged.
# Used by tests/test-notify-diff.sh. End-users should not set this.
HITHER_NOTIFY_DRY_RUN="${HITHER_NOTIFY_DRY_RUN:-0}"

LOG_DIR="${HOME}/Library/Logs/hither"
LOG_FILE="${LOG_DIR}/sync.log"
mkdir -p "${LOG_DIR}"

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" | tee -a "${LOG_FILE}" >&2
}

die() { log "FATAL: $*"; exit 1; }

# ---------------------------------------------------------------------------
# URL-encoding (v0.5.5)
# ---------------------------------------------------------------------------
#
# Percent-encode a string per RFC 3986 unreserved-set rules. Pure zsh; no
# external deps (curl/python/jq not available at sourcing-time in test
# extraction contexts).
#
# Unreserved per RFC 3986: A-Z a-z 0-9 - . _ ~
# Everything else gets %HH-encoded by the BYTE value. This is what
# mount_smbfs's URL parser expects between the user and the `@` separator
# in `//user:URL_ENCODED_PW@host/share`.
#
# zsh-specific notes:
#   - ${#s} counts bytes when MULTIBYTE is unset; counts codepoints when set.
#     Either is fine for our purpose — the case statement matches one
#     ${s[i]} unit per iteration, and we %HH-encode the byte value via
#     printf '%%%02X' "'$c" (the leading apostrophe makes printf treat the
#     arg as a character literal and emit its numeric value).
#   - For a multi-byte codepoint under MULTIBYTE, $c is the full codepoint
#     and "'$c" returns the codepoint number, NOT the UTF-8 byte sequence.
#     Toggling MULTIBYTE off for the loop ensures we emit byte-level %HH
#     for non-ASCII, which is what RFC 3986 mandates for "binary octets".
url_encode() {
  emulate -L zsh
  unsetopt MULTIBYTE 2>/dev/null || true
  local s="$1" out="" i c
  for (( i=1; i<=${#s}; i++ )); do
    c="${s[i]}"
    case "$c" in
      [A-Za-z0-9_.~-]) out+="$c" ;;
      *) out+=$(printf '%%%02X' "'$c") ;;
    esac
  done
  printf '%s' "$out"
}

# Required external tools.
for cmd in curl jq sudo security; do
  command -v "$cmd" >/dev/null || die "missing required tool: $cmd"
done

# ---------------------------------------------------------------------------
# Single-flight lock (v0.5.3)
# ---------------------------------------------------------------------------
#
# Two concurrent invocations — the 04:23 LaunchAgent firing while a user
# also runs `hither sync` manually, or a teammate runs both at once — race
# the wrapper. The wrapper itself is atomic per-call, but the two-step
# read-DSM-then-write-map sequence isn't: caller A can read shares, caller B
# can read shares, both call the wrapper in sequence, and the LAST write
# wins. With DSM share-list filtering being deterministic, the result is
# usually identical and the race is benign — but it spends 2× the DSM
# auth tokens and trips the notification path twice for the same change.
#
# Pattern matches bootstrap/apply-auto-master.sh (mkdir mutex + stale TTL).
# Lives at ${HOME}/Library/Caches/hither/sync.lock — user-writable; the
# LaunchAgent runs as the user, so a /var/run/ root-owned lock would
# require sudo just to acquire (worse than the race we're fixing).
#
# TTL: 600s. A normal sync against 2-3 NASes completes in well under 60s.
# 10 minutes is unambiguously stale (SIGKILL'd or wedged DSM call).
#
# HITHER_LOCK_DIR override: tests set this to a tempdir so they don't
# race the user's real sync; HITHER_SKIP_LOCK=1 (also test-only) disables
# the lock entirely for the in-script verification path.
LOCK_DIR="${HITHER_LOCK_DIR:-${HOME}/Library/Caches/hither}"
LOCK="${LOCK_DIR}/sync.lock"
LOCK_TTL_SEC=600
if [[ "${HITHER_SKIP_LOCK:-0}" != "1" ]]; then
  mkdir -p "${LOCK_DIR}"
  if [[ -d "${LOCK}" ]]; then
    lock_mtime=$(stat -f %m "${LOCK}" 2>/dev/null || echo 0)
    lock_age=$(( $(date +%s) - lock_mtime ))
    # Two stale conditions: age > TTL (the normal case), OR age < 0 (clock
    # skew — lock has a future mtime, which can happen on first-boot Macs
    # before NTP sync, or after manual `date` rewrites). Either way the
    # lock is unreliable; break it.
    if (( lock_age > LOCK_TTL_SEC )) || (( lock_age < 0 )); then
      log "[warn] stale lock ${LOCK} (age=${lock_age}s, TTL=${LOCK_TTL_SEC}s — clock skew if negative) — breaking"
      rmdir "${LOCK}" 2>/dev/null || true
    fi
  fi
  if ! mkdir "${LOCK}" 2>/dev/null; then
    log "another hither-sync is in flight (${LOCK}); exiting"
    # Graceful no-op for concurrent fire — NOT an error condition.
    exit 0
  fi
  trap 'rmdir "${LOCK}" 2>/dev/null || true' EXIT
fi

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
  #
  # v0.5.5: on success, also writes the resolved cleartext password to the
  # script-scope variable HITHER_LAST_DSM_PASSWORD so the main loop can
  # thread it into render_map for URL-encoded embedding in the map file.
  # NOT exported — process-internal only. Cleared on failure paths.
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
  [[ "${ok}" == "true" ]] || { HITHER_LAST_DSM_PASSWORD=""; log "  DSM auth failed: $(echo "$resp" | jq -c '.error // empty')"; return 1; }
  sid=$(echo "${resp}" | jq -r '.data.sid')
  # v0.5.5: stash for render_map. NOT printed; only the SID goes to stdout.
  HITHER_LAST_DSM_PASSWORD="${password}"
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
  # Args: <nas-host> <password>
  # Reads share names on stdin, emits an /etc/hither_<nas> file body.
  #
  # v0.5.5: the password is URL-encoded and embedded into each map line
  # between the user and the `@` separator:
  #   ://<user>:<URL_ENCODED_PW>@<host>/<share>
  #
  # Why on-disk cleartext: macOS `mount_smbfs` cannot reliably authenticate
  # via Keychain entries created by the `security` CLI — only Finder's
  # Cmd-K creates entries with the right ACL+attribute hookup. NetFS /
  # AppleScript / Finder all work with our CLI-created Keychain entries,
  # but `mount_smbfs` (which `automountd` invokes internally) rejects them
  # with "Authentication error" even though the byte-for-byte password match
  # is correct. Forcing the user to Cmd-K once after `hither subscribe`
  # defeats the fully-automated goal. URL-embedded creds work every time
  # without any Keychain lookup.
  #
  # Threat-model summary: the file is written mode 0600 (root r+w only) by
  # hither-write-map. Anyone with root on the Mac could `security
  # find-internet-password -w` the same password out of Keychain — so the
  # on-disk form does NOT widen the attack surface. See docs/design-decisions.md.
  local nas="$1" password="$2"
  local encoded_pw
  encoded_pw=$(url_encode "${password}")
  printf '# /etc/hither_%s — AutoFS indirect map.\n' "${nas}"
  printf '# MANAGED BY hither sync — DO NOT EDIT BY HAND.\n'
  printf '# Generated: %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')"
  printf '# Target user: %s\n' "${TARGET_USER}"
  printf '# Format: <share-key>  -fstype=smbfs,soft  ://<user>:<url-encoded-pw>@<host>/<share>\n'
  printf '\n'
  while IFS= read -r share; do
    [[ -z "${share}" ]] && continue
    printf '%-50s -fstype=smbfs,soft ://%s:%s@%s/%s\n' \
      "${share}" "${TARGET_USER}" "${encoded_pw}" "${nas}" "${share}"
  done
}

# ---------------------------------------------------------------------------
# Share-set diff (v0.5) — surface added/removed shares via notification
# ---------------------------------------------------------------------------

extract_share_set_from_map() {
  # Reads an /etc/hither_<nas> map body on stdin, prints sorted share names
  # (first whitespace-delimited token of each non-comment, non-blank line).
  #
  # Render-time format: `<share>  -fstype=smbfs,soft ://<user>@<host>/<share>`
  # — so $1 is the share key.
  awk '/^[[:space:]]*#/ {next} /^[[:space:]]*$/ {next} {print $1}' | sort -u
}

compute_change_summary() {
  # Args: <added-file> <removed-file>
  # Both files are sorted share-name lists, one per line. Either may be
  # empty. Prints a human-readable summary on stdout suitable for the
  # body of a macOS notification. Capped at ~150 chars (macOS truncates).
  #
  # Empty input on both sides: prints empty (caller should not fire).
  local added_file="$1" removed_file="$2"
  local added_count=0 removed_count=0
  # Count non-blank lines. AVOID `grep -c ... || echo 0` — that's the
  # v0.4.1 pre-publication bug: grep prints "0" AND exits non-zero on
  # zero matches, so the || branch runs and you get "0\n0" in the
  # capture, which breaks arithmetic context. Use awk: it always exits 0
  # and prints exactly what we asked for.
  if [[ -s "${added_file}" ]]; then
    added_count=$(awk 'NF { c++ } END { print c+0 }' "${added_file}")
  fi
  if [[ -s "${removed_file}" ]]; then
    removed_count=$(awk 'NF { c++ } END { print c+0 }' "${removed_file}")
  fi

  if (( added_count == 0 && removed_count == 0 )); then
    printf ''
    return 0
  fi

  # Compact form when total changes <= 3: enumerate names.
  # Otherwise: numeric summary.
  if (( added_count + removed_count <= 3 )); then
    # paste(1) on macOS does NOT accept multi-char delimiters via -d;
    # we get only the first character. Use awk to assemble ", "-joined
    # CSVs explicitly.
    local added_csv removed_csv summary=""
    added_csv=$(awk 'NF { if (out) out = out ", " $0; else out = $0 } END { print out }' "${added_file}" 2>/dev/null)
    removed_csv=$(awk 'NF { if (out) out = out ", " $0; else out = $0 } END { print out }' "${removed_file}" 2>/dev/null)
    if [[ -n "${added_csv}" && -n "${removed_csv}" ]]; then
      summary="+ ${added_csv} / − ${removed_csv}"
    elif [[ -n "${added_csv}" ]]; then
      summary="+ ${added_csv}"
    else
      summary="− ${removed_csv}"
    fi
    printf '%s\n' "${summary}"
  else
    printf '+ %d new, − %d removed\n' "${added_count}" "${removed_count}"
  fi
}

fire_notification() {
  # Args: <nas> <body>
  # Fires a macOS user notification via osascript. Wrapped in `|| true` —
  # a notification-system failure must NEVER break the sync. Truncates
  # body to 150 chars (macOS NSUserNotification truncates around there
  # anyway; we cap explicitly so the log shows what was actually sent).
  local nas="$1" body="$2"
  local title="Hither — ${nas}"

  # Hard cap. Truncate to 150 BYTES (macOS notifications truncate display
  # anyway; multi-byte glyphs at byte 150 may split — acceptable trade-off
  # for zero-dep, given BWK awk's substr is byte-indexed not codepoint-indexed).
  if (( ${#body} > 150 )); then
    body="$(printf '%s' "${body}" | awk '{print substr($0, 1, 147) "..."}')"
  fi

  # Escape for AppleScript double-quoted string literals. AppleScript
  # interpolates ALL of: backslash, double-quote, dollar (in some
  # contexts via shell-passthrough), and backtick. Escape all four
  # defensively — the share names that reach this function are bounded
  # by DSM share-name validation, but cheap insurance.
  local esc_title esc_body
  esc_title="${title//\\/\\\\}"
  esc_title="${esc_title//\"/\\\"}"
  esc_title="${esc_title//\$/\\\$}"
  esc_title="${esc_title//\`/\\\`}"
  esc_body="${body//\\/\\\\}"
  esc_body="${esc_body//\"/\\\"}"
  esc_body="${esc_body//\$/\\\$}"
  esc_body="${esc_body//\`/\\\`}"

  if [[ "${HITHER_NOTIFY_DRY_RUN}" == "1" ]]; then
    log "  [notify dry-run] osascript -e 'display notification \"${esc_body}\" with title \"${esc_title}\"'"
    return 0
  fi

  # 5-second timeout via perl alarm — osascript can hang indefinitely if
  # Notification Center is wedged. perl ships with macOS; no coreutils
  # dep. Subshell isolates the alarm so it can't leak to the parent.
  #
  # v0.5.3: capture exit status. Previously this branch unconditionally
  # logged "notification fired" even when the perl alarm fired (NC wedged,
  # process killed) — a log lie that hid delivery failures from operators
  # debugging "I never got a notification."
  if ( perl -e 'alarm 5; exec @ARGV' /usr/bin/osascript -e "display notification \"${esc_body}\" with title \"${esc_title}\"" ) 2>/dev/null; then
    log "  notification dispatched: ${title} — ${body}"
  else
    log "  [warn] notification dispatch timed out or failed for ${title} (alarm or osascript non-zero) — ${body}"
  fi
}

apply_map_if_changed() {
  # Args: <nas-host>  (reads desired body on stdin)
  # Diffs against /etc/hither_<nas>; if changed (or if a needs-reload marker
  # is present from a prior failed automount), sudo-writes + reloads.
  # When HITHER_NOTIFY=1 and the share-SET membership differs (not just
  # ordering/whitespace), fires a macOS user notification after a
  # successful write.
  local nas="$1"
  local map_path="/etc/hither_${nas}"
  local marker_path="/etc/hither_${nas}.needs-reload"
  local desired_body
  desired_body=$(cat)

  local current_body=""
  [[ -f "${map_path}" ]] && current_body=$(< "${map_path}")

  # --- v0.5: extract share-sets BEFORE applying the diff. -----------------
  # We do this even when no notification will fire — the cost is two tiny
  # awk passes and the code path is simpler than threading a conditional
  # through the whole function.
  #
  # `is_initial`: no previous on-disk map means this is the first sync
  # for this NAS. We don't fire notifications on initial sync — every
  # share would show up as "added", which is noise rather than signal.
  local is_initial=0
  [[ -z "${current_body}" ]] && is_initial=1

  local set_tmp_dir
  set_tmp_dir=$(mktemp -d -t "hither-diff-${nas}.XXXXXX")
  local current_set="${set_tmp_dir}/current" desired_set="${set_tmp_dir}/desired"
  local added_set="${set_tmp_dir}/added"     removed_set="${set_tmp_dir}/removed"
  printf '%s\n' "${current_body}" | extract_share_set_from_map > "${current_set}"
  printf '%s\n' "${desired_body}" | extract_share_set_from_map > "${desired_set}"
  comm -13 "${current_set}" "${desired_set}" > "${added_set}"   # in desired, not in current
  comm -23 "${current_set}" "${desired_set}" > "${removed_set}" # in current, not in desired

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
    rm -rf "${set_tmp_dir}"
    return 0
  fi

  if [[ -f "${marker_path}" ]]; then
    log "  ${marker_path} present (prior automount -cv failure) — forcing retry via wrapper"
  else
    log "  diff detected for ${map_path} — applying via hither-write-map wrapper"
  fi
  if ! printf '%s\n' "${desired_body}" \
    | sudo -n /usr/local/sbin/hither-write-map "${nas}" >/dev/null; then
    log "  hither-write-map failed (wrapper handles both tee + automount -cv atomically)"
    rm -rf "${set_tmp_dir}"
    return 1
  fi

  log "  ${map_path} updated; automount -cv invoked by wrapper"

  # --- v0.5: fire notification if share-set membership changed. -----------
  # Gate on (a) opted in via HITHER_NOTIFY, (b) not initial sync,
  # (c) at least one share added or removed (not just file-body churn).
  if [[ "${HITHER_NOTIFY}" == "1" && "${is_initial}" -eq 0 ]]; then
    local summary
    summary="$(compute_change_summary "${added_set}" "${removed_set}")"
    if [[ -n "${summary}" ]]; then
      fire_notification "${nas}" "${summary}"
    else
      log "  share-set unchanged (file body churned but membership stable) — no notification"
    fi
  elif [[ "${HITHER_NOTIFY}" == "1" && "${is_initial}" -eq 1 ]]; then
    log "  initial sync for ${nas} — suppressing notification (every share would be 'added')"
  fi

  rm -rf "${set_tmp_dir}"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

log "hither-sync start (target_user=${TARGET_USER}, nas_list='${NAS_LIST}')"

# v0.5.5: script-scope. Set by dsm_login on success; consumed by render_map.
HITHER_LAST_DSM_PASSWORD=""

exit_code=0
for nas in ${(z)NAS_LIST}; do
  log "processing ${nas}"
  if ! sid=$(dsm_login "${nas}"); then
    log "  skipping ${nas} (auth failed)"
    # v0.5.3: surface auth failure via notification when opted in.
    # Until now a stale Keychain entry produced a single line in
    # ~/Library/Logs/hither/sync.log and zero user-visible signal — users
    # discovered the problem only when a stale `cd /Hither/<nas>/<share>`
    # tripped a "No such file or directory". Fire a notification so the
    # next sync surfaces the stale-credential condition immediately.
    if [[ "${HITHER_NOTIFY:-0}" == "1" ]]; then
      fire_notification "${nas}" "DSM auth failed — credential may be stale (run: hither subscribe ${nas} --user <dsm-user> to re-prompt)"
    fi
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
      # v0.5.5: pass cleartext password (resolved by dsm_login) to render_map
      # for URL-encoded embedding in the map line. See render_map docblock
      # for the why; the file is written mode 0600 by hither-write-map.
      printf '%s\n' "${shares}" \
        | render_map "${nas}" "${HITHER_LAST_DSM_PASSWORD}" \
        | apply_map_if_changed "${nas}" \
        || exit_code=1
    fi
  } always {
    dsm_logout "${nas}" "${sid}"
    # v0.5.5: scrub the cleartext from the script-scope var between NASes.
    HITHER_LAST_DSM_PASSWORD=""
  }
done

log "hither-sync done (exit ${exit_code})"
exit "${exit_code}"
