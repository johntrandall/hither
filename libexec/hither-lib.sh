#!/bin/bash
# SPDX-License-Identifier: MIT
# libexec/hither-lib.sh — shared bash helpers sourced by bin/hither.
#
# All functions here operate on the subscription-config layout:
#   ~/.config/hither/subscriptions/<nas>.toml
#
# The TOML is intentionally simple (flat key=value, no nested arrays) so
# we can parse it with `grep`+`sed` without taking a TOML-parser dependency.
# Hither's whole point is "no external deps beyond what macOS ships."

# Guard against double-sourcing.
if [[ "${_HITHER_LIB_LOADED:-0}" == "1" ]]; then
  return 0 2>/dev/null || true
fi
_HITHER_LIB_LOADED=1

HITHER_CONFIG_DIR="${HITHER_CONFIG_DIR:-${HOME}/.config/hither}"
HITHER_SUBS_DIR="${HITHER_CONFIG_DIR}/subscriptions"

# Where the LaunchAgent plist lives once installed.
HITHER_AGENT_LABEL="com.johnrandall.hither.sync"
HITHER_AGENT_PATH="${HOME}/Library/LaunchAgents/${HITHER_AGENT_LABEL}.plist"

# --- Validation ----------------------------------------------------------

hither_validate_nas_name() {
  # Args: <nas>
  # Same regex enforced by /usr/local/sbin/hither-write-map. Keeping it
  # identical here lets us reject bad names at config time, before they
  # ever reach the wrapper.
  local nas="$1"
  if [[ ! "$nas" =~ ^[a-z0-9-]+$ ]]; then
    return 1
  fi
  return 0
}

# --- Subscription file I/O -----------------------------------------------

hither_sub_path() {
  # Args: <nas>
  printf '%s/%s.toml\n' "${HITHER_SUBS_DIR}" "$1"
}

hither_sub_exists() {
  # Args: <nas>
  [[ -f "$(hither_sub_path "$1")" ]]
}

hither_sub_read_field() {
  # Args: <file> <key>
  # Returns the value of a top-level <key> = "<value>" or <key> = <int> line.
  # Strips surrounding quotes. Returns empty if not found.
  local file="$1" key="$2"
  [[ -f "$file" ]] || return 1
  # Match `key = "value"` or `key = value`; tolerate spaces around `=`.
  awk -v k="$key" '
    $0 ~ "^[[:space:]]*" k "[[:space:]]*=" {
      sub(/^[^=]*=[[:space:]]*/, "", $0)
      gsub(/^"|"$/, "", $0)
      print
      exit
    }
  ' "$file"
}

hither_sub_write() {
  # Args: <nas> <user> <proto> <hour> <minute>
  # Writes the subscription TOML atomically.
  local nas="$1" user="$2" proto="$3" hour="$4" minute="$5"
  local dest tmp
  dest="$(hither_sub_path "$nas")"
  tmp="${dest}.tmp.$$"
  mkdir -p "${HITHER_SUBS_DIR}"
  cat > "${tmp}" <<TOML
# Hither subscription. Managed by \`hither subscribe / unsubscribe\`.
# Do not hand-edit — fields are read by bin/hither at run time.

[subscription]
name = "${nas}"
user = "${user}"
nas_proto = "${proto}"
schedule_hour = ${hour}
schedule_minute = ${minute}

[meta]
added = "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
hither_version = "${HITHER_VERSION:-unknown}"
TOML
  chmod 0600 "${tmp}"
  mv -f "${tmp}" "${dest}"
}

hither_sub_delete() {
  # Args: <nas>
  local path
  path="$(hither_sub_path "$1")"
  if [[ -f "${path}" ]]; then
    rm -f "${path}"
  fi
}

hither_sub_list_names() {
  # Lists subscription names (NAS hostnames), one per line, sorted.
  # Empty if no subscriptions exist.
  [[ -d "${HITHER_SUBS_DIR}" ]] || return 0
  local f base
  for f in "${HITHER_SUBS_DIR}"/*.toml; do
    [[ -f "$f" ]] || continue
    base="$(basename "$f" .toml)"
    printf '%s\n' "${base}"
  done | sort
}

hither_sub_iter() {
  # Echoes one line per subscription, tab-separated:
  #   <nas>\t<user>\t<proto>\t<hour>\t<minute>
  local nas path user proto hour minute
  while IFS= read -r nas; do
    [[ -n "$nas" ]] || continue
    path="$(hither_sub_path "$nas")"
    user="$(hither_sub_read_field "$path" user)"
    proto="$(hither_sub_read_field "$path" nas_proto)"
    hour="$(hither_sub_read_field "$path" schedule_hour)"
    minute="$(hither_sub_read_field "$path" schedule_minute)"
    printf '%s\t%s\t%s\t%s\t%s\n' "$nas" "$user" "$proto" "$hour" "$minute"
  done < <(hither_sub_list_names)
}

# --- LaunchAgent refresh -------------------------------------------------

hither_refresh_launchagent_env() {
  # Re-render ~/Library/LaunchAgents/com.johnrandall.hither.sync.plist with
  # NAS_LIST / TARGET_USER derived from the current subscription set, then
  # bootout+bootstrap so launchd picks up the new env.
  #
  # No-op (with a warning) if the agent plist isn't installed yet —
  # `hither bootstrap --user-only` is the install path.
  local src="${HITHER_ROOT}/launchd/com.johnrandall.hither.sync.plist"
  if [[ ! -f "${HITHER_AGENT_PATH}" ]]; then
    echo "[skip] LaunchAgent not installed yet; refresh deferred until 'hither bootstrap --user-only'" >&2
    return 0
  fi
  if [[ ! -f "${src}" ]]; then
    echo "ERROR: LaunchAgent template missing at ${src}" >&2
    return 1
  fi

  # Collect NAS_LIST and TARGET_USER from subscriptions. v0.3 assumes a
  # single TARGET_USER per Mac (DSM identity). If multiple subscriptions
  # disagree on `user`, we pick the first and warn — multi-user support
  # is post-v1.0 (see roadmap "Out-of-scope").
  local first_user="" nas_list="" iter_user iter_nas
  while IFS=$'\t' read -r iter_nas iter_user _ _ _; do
    [[ -n "$iter_nas" ]] || continue
    if [[ -z "$first_user" ]]; then
      first_user="$iter_user"
    elif [[ "$first_user" != "$iter_user" ]]; then
      echo "[warn] subscription ${iter_nas} uses user '${iter_user}' but LaunchAgent runs as '${first_user}' — multi-user support is post-v1.0" >&2
    fi
    if [[ -z "$nas_list" ]]; then
      nas_list="$iter_nas"
    else
      nas_list="${nas_list} ${iter_nas}"
    fi
  done < <(hither_sub_iter)

  if [[ -z "$nas_list" ]]; then
    echo "[skip] no subscriptions — LaunchAgent left untouched. Use 'hither unsubscribe' if you want it removed entirely." >&2
    return 0
  fi

  # Re-render. Substitute __HOME__, then patch NAS_LIST/TARGET_USER via
  # sed against the EnvironmentVariables block. We're replacing the
  # values that follow the literal <key>TARGET_USER</key> and
  # <key>NAS_LIST</key> lines.
  local tmp="${HITHER_AGENT_PATH}.tmp.$$"
  sed "s|__HOME__|${HOME}|g" "${src}" > "${tmp}"
  # Replace TARGET_USER value (line immediately after its <key>).
  /usr/bin/awk -v u="${first_user}" -v l="${nas_list}" '
    BEGIN { mode = "" }
    {
      if (mode == "user") {
        sub(/<string>[^<]*<\/string>/, "<string>" u "</string>")
        mode = ""
      } else if (mode == "list") {
        sub(/<string>[^<]*<\/string>/, "<string>" l "</string>")
        mode = ""
      }
      print
      if ($0 ~ /<key>TARGET_USER<\/key>/) mode = "user"
      else if ($0 ~ /<key>NAS_LIST<\/key>/) mode = "list"
    }
  ' "${tmp}" > "${tmp}.2"
  mv -f "${tmp}.2" "${tmp}"
  chmod 0644 "${tmp}"

  if ! plutil -lint "${tmp}" >/dev/null; then
    echo "ERROR: refreshed plist failed plutil -lint — leaving old plist in place" >&2
    rm -f "${tmp}"
    return 1
  fi

  mv -f "${tmp}" "${HITHER_AGENT_PATH}"

  # Reload so launchd picks up the new env immediately.
  local domain="gui/$(id -u)"
  launchctl bootout "${domain}/${HITHER_AGENT_LABEL}" 2>/dev/null || true
  if launchctl bootstrap "${domain}" "${HITHER_AGENT_PATH}"; then
    echo "[ok] LaunchAgent reloaded with NAS_LIST='${nas_list}' TARGET_USER='${first_user}'"
  else
    echo "ERROR: launchctl bootstrap ${domain} failed after refresh" >&2
    return 1
  fi
}
