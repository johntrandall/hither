#!/bin/zsh
# SPDX-License-Identifier: MIT
# tests/test-launchagent-env.sh — verify hither_refresh_launchagent_env
# correctly OR-aggregates notify_on_changes across subscriptions and
# materializes the LaunchAgent plist's env block.
#
# Closes the test-coverage gap surfaced by the v0.5.0 iterative-
# verification round: the share-set diff logic was unit-tested in
# test-notify-diff.sh, but the path that wires it up (env-var rendering
# from the subscription set) was only exercised end-to-end against a
# real LaunchAgent.
#
# Strategy:
#   1. Build a tempdir of fake subscription TOMLs (mix of notify=true/false).
#   2. Stage a copy of the LaunchAgent plist template in the tempdir.
#   3. Override HITHER_SUBS_DIR + HITHER_AGENT_PATH to point at the tempdir.
#   4. Stub `launchctl` (the real one would touch the user's actual agent).
#   5. Call hither_refresh_launchagent_env.
#   6. Assert plutil -lint passes; assert HITHER_NOTIFY / NAS_LIST /
#      TARGET_USER values match expectations.
#
# Run: zsh tests/test-launchagent-env.sh
# Exit: 0 on all-pass; 1 on any failure.

if [[ -z "${ZSH_VERSION:-}" ]]; then
  echo "ERROR: this test requires zsh; run: zsh $0" >&2
  exit 1
fi

set -uo pipefail

HERE="${0:A:h}"
PROJECT_ROOT="${HERE:h}"

LIB_SH="${PROJECT_ROOT}/libexec/hither-lib.sh"
PLIST_TEMPLATE="${PROJECT_ROOT}/launchd/com.johnrandall.hither.sync.plist"
[[ -f "${LIB_SH}" ]]         || { echo "FATAL: ${LIB_SH} not found"; exit 1; }
[[ -f "${PLIST_TEMPLATE}" ]] || { echo "FATAL: ${PLIST_TEMPLATE} not found"; exit 1; }

pass=0
fail=0
report() {
  # Args: <name> <expected> <actual>
  local name="$1" expected="$2" actual="$3"
  if [[ "${expected}" == "${actual}" ]]; then
    printf '  [PASS] %s\n' "${name}"
    pass=$(( pass + 1 ))
  else
    printf '  [FAIL] %s\n' "${name}"
    printf '         expected: %s\n' "${expected}"
    printf '         actual:   %s\n' "${actual}"
    fail=$(( fail + 1 ))
  fi
}

# ---------------------------------------------------------------------------
# Helper: read the materialized value for a given plist env key.
#
# Format of the relevant block:
#   <key>HITHER_NOTIFY</key>
#   <string>0</string>
# We grep the line after the <key>FOO</key> match and strip the <string>
# tags. Defensive: the awk lookup is local to this test (not exported).
# ---------------------------------------------------------------------------
read_plist_env() {
  local plist="$1" key="$2"
  awk -v k="${key}" '
    found && /<string>[^<]*<\/string>/ {
      match($0, /<string>[^<]*<\/string>/)
      s = substr($0, RSTART, RLENGTH)
      sub(/^<string>/, "", s)
      sub(/<\/string>$/, "", s)
      print s
      exit
    }
    $0 ~ "<key>" k "</key>" { found = 1 }
  ' "${plist}"
}

run_case() {
  # Args: <case-name> <notify-list> <expected-HITHER_NOTIFY>
  # <notify-list> is a comma-separated list like "true,false,true".
  local case_name="$1" notify_list="$2" expected_notify="$3"

  local tmpdir
  tmpdir=$(mktemp -d -t hither-laenv.XXXXXX)
  trap "rm -rf ${tmpdir}" EXIT

  # Stage tempdir layout. The library derives HITHER_SUBS_DIR from
  # HITHER_CONFIG_DIR at source time (it's NOT independently overridable
  # post-source unless we re-assign after sourcing — which we do below).
  # We place subs at <tmpdir>/subscriptions so HITHER_CONFIG_DIR=<tmpdir>
  # naturally points the lib at the right place too.
  mkdir -p "${tmpdir}/subscriptions"
  mkdir -p "${tmpdir}/launchagents"
  local agent_dst="${tmpdir}/launchagents/com.johnrandall.hither.sync.plist"
  # Stage the agent in materialized form (HOME substituted) so the test
  # mirrors what bootstrap_user_phase writes to ~/Library/LaunchAgents.
  sed "s|__HOME__|${tmpdir}|g" "${PLIST_TEMPLATE}" > "${agent_dst}"
  chmod 0644 "${agent_dst}"

  # Write one subscription per notify entry. Use deterministic names so
  # NAS_LIST ordering is predictable.
  local idx=0 entry
  for entry in ${(s:,:)notify_list}; do
    idx=$(( idx + 1 ))
    local name="testnas${idx}"
    cat > "${tmpdir}/subscriptions/${name}.toml" <<TOML
[subscription]
name = "${name}"
user = "testuser"
nas_proto = "http"
schedule_hour = 4
schedule_minute = 23
notify_on_changes = ${entry}

[meta]
added = "2026-01-01T00:00:00Z"
hither_version = "test"
TOML
    chmod 0600 "${tmpdir}/subscriptions/${name}.toml"
  done

  # Source the library with overridden paths. Use a subshell so each case
  # is isolated. Stub launchctl to a no-op that always succeeds — the real
  # binary would touch the actual user agent.
  local stub_bin="${tmpdir}/stub-bin"
  mkdir -p "${stub_bin}"
  cat > "${stub_bin}/launchctl" <<'STUB'
#!/bin/sh
exit 0
STUB
  chmod 0755 "${stub_bin}/launchctl"

  local lint_rc notify_val nas_val user_val
  # Run in a child BASH process — the library is bash-shebanged and uses
  # bash-specific patterns that don't translate cleanly into zsh process
  # substitution (`<(...)` PATH inheritance differs). The test harness
  # is zsh-only (per shell-guard above), but the library-under-test is
  # bash. The two interop fine via env-var passthrough.
  PATH="${stub_bin}:${PATH}" \
  HITHER_CONFIG_DIR="${tmpdir}" \
  HITHER_ROOT="${PROJECT_ROOT}" \
  HITHER_TEST_AGENT_PATH="${agent_dst}" \
  HITHER_TEST_SUBS_DIR="${tmpdir}/subscriptions" \
  bash -c '
    . "'"${LIB_SH}"'"
    HITHER_SUBS_DIR="${HITHER_TEST_SUBS_DIR}"
    HITHER_AGENT_PATH="${HITHER_TEST_AGENT_PATH}"
    hither_refresh_launchagent_env
  ' >/dev/null 2>&1

  # plutil -lint check.
  if plutil -lint "${agent_dst}" >/dev/null 2>&1; then
    lint_rc=0
  else
    lint_rc=1
  fi
  report "${case_name}: plutil -lint passes" "0" "${lint_rc}"

  notify_val=$(read_plist_env "${agent_dst}" HITHER_NOTIFY)
  report "${case_name}: HITHER_NOTIFY=${expected_notify}" "${expected_notify}" "${notify_val}"

  user_val=$(read_plist_env "${agent_dst}" TARGET_USER)
  report "${case_name}: TARGET_USER=testuser" "testuser" "${user_val}"

  nas_val=$(read_plist_env "${agent_dst}" NAS_LIST)
  # Build expected NAS_LIST from notify_list length (testnas1 testnas2 ...).
  local expected_nas="" i n
  n=$(printf '%s' "${notify_list}" | awk -F, '{print NF}')
  for (( i=1; i<=n; i++ )); do
    if [[ -z "${expected_nas}" ]]; then
      expected_nas="testnas${i}"
    else
      expected_nas="${expected_nas} testnas${i}"
    fi
  done
  report "${case_name}: NAS_LIST='${expected_nas}'" "${expected_nas}" "${nas_val}"

  rm -rf "${tmpdir}"
  trap - EXIT
}

echo "== hither_refresh_launchagent_env =="

# Case A: single sub, notify=true → HITHER_NOTIFY=1
run_case "single notify=true" "true" "1"

# Case B: single sub, notify=false → HITHER_NOTIFY=0
run_case "single notify=false" "false" "0"

# Case C: three subs, all false → HITHER_NOTIFY=0
run_case "three all-false" "false,false,false" "0"

# Case D: three subs, one true → HITHER_NOTIFY=1 (any-true OR)
run_case "three one-true (OR)" "false,true,false" "1"

# Case E: three subs, all true → HITHER_NOTIFY=1
run_case "three all-true" "true,true,true" "1"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
echo "== Summary =="
echo "  passed: ${pass}"
echo "  failed: ${fail}"
if (( fail > 0 )); then
  exit 1
fi
exit 0
