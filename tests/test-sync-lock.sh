#!/bin/zsh
# SPDX-License-Identifier: MIT
# tests/test-sync-lock.sh — verify the single-flight lock in
# libexec/hither-sync.sh.
#
# Scope: ONLY the lock acquire / stale-TTL-break / EXIT-release behavior.
# We don't run the full sync (that requires DSM creds, a real NAS, etc.) —
# we exercise the lock logic via the shell-snippet block that lives at the
# top of hither-sync.sh, with overrides set so the test never touches the
# user's real lock dir or fires anything real.
#
# Override knobs (test-only):
#   HITHER_LOCK_DIR  — repoint the lock to a tempdir
#   HITHER_SKIP_LOCK — disable the lock entirely (used to verify the OFF
#                      path doesn't regress — second invocation should run)
#
# Run: zsh tests/test-sync-lock.sh
# Exit: 0 on all-pass; 1 on any failure.

if [[ -z "${ZSH_VERSION:-}" ]]; then
  echo "ERROR: this test requires zsh; run: zsh $0" >&2
  exit 1
fi

set -uo pipefail

HERE="${0:A:h}"
PROJECT_ROOT="${HERE:h}"
SYNC_SH="${PROJECT_ROOT}/libexec/hither-sync.sh"

[[ -f "${SYNC_SH}" ]] || { echo "FATAL: ${SYNC_SH} not found"; exit 1; }

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
# Extract just the lock-acquire block from hither-sync.sh so we can test it
# in isolation without invoking the full sync. The block is bracketed by a
# documented header (`# Single-flight lock (v0.5.3)`) and ends with the
# `trap … EXIT` line. We pluck out the active lines via awk.
# ---------------------------------------------------------------------------
extract_lock_block() {
  # State machine: enter on the header comment, then keep printing until
  # we see the closing `fi` for the outer `if [[ "${HITHER_SKIP_LOCK:-0}" …`.
  # The block contains exactly one outer `if` and one matching `fi` at
  # column 0; print through that closing fi and stop.
  awk '
    /^# Single-flight lock \(v0\.5\.3\)/ { in_block=1; next }
    in_block { print }
    in_block && /^fi$/ { exit }
  ' "${SYNC_SH}"
}

LOCK_BLOCK_CONTENT=$(extract_lock_block)
# Sanity: refuse to run if extraction yielded nothing — the block was
# either renamed or removed and the test is no longer wired correctly.
if [[ -z "${LOCK_BLOCK_CONTENT}" ]] || ! echo "${LOCK_BLOCK_CONTENT}" | grep -q 'mkdir "${LOCK}"'; then
  echo "FATAL: could not extract the lock-acquire block from ${SYNC_SH}"
  echo "       (test wiring is stale — re-check the block header in hither-sync.sh)"
  exit 1
fi

# Shared harness: builds a zsh runner that sources the lock block with
# HITHER_LOCK_DIR pointed at our tempdir. log() is stubbed to /dev/null so
# the test output stays clean.
make_runner() {
  local tmpdir="$1" runner="$2"
  cat > "${runner}" <<RUNNER
#!/bin/zsh
set -uo pipefail
HITHER_LOCK_DIR="${tmpdir}"
log() { :; }  # silence
${LOCK_BLOCK_CONTENT}
# If we got here, the lock was acquired successfully.
printf 'ACQUIRED\n'
# Hold the lock briefly so a parallel invocation observes it.
sleep "\${HOLD_SECS:-0.5}"
RUNNER
  chmod 0755 "${runner}"
}

echo "== single-flight lock =="

# ---------------------------------------------------------------------------
# Case A: First acquire succeeds; second concurrent acquire is rejected.
# ---------------------------------------------------------------------------
tmpdir_a=$(mktemp -d -t hither-lock-a.XXXXXX)
runner_a="${tmpdir_a}/runner.zsh"
make_runner "${tmpdir_a}" "${runner_a}"

# Fire the first runner in the background; let it hold the lock for 1.5s.
HOLD_SECS=1.5 "${runner_a}" > "${tmpdir_a}/out1" 2>&1 &
pid1=$!
# Wait briefly for the lock to be acquired.
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [[ -d "${tmpdir_a}/sync.lock" ]] && break
  sleep 0.05
done

# Fire the second runner now — it should see the lock and exit without
# printing ACQUIRED.
HOLD_SECS=0 "${runner_a}" > "${tmpdir_a}/out2" 2>&1
rc2=$?

# Reap the first runner.
wait "${pid1}"
rc1=$?

# First runner should have acquired and exited 0.
if grep -q '^ACQUIRED$' "${tmpdir_a}/out1"; then
  acquired1="yes"
else
  acquired1="no"
fi
report "first acquire prints ACQUIRED" "yes" "${acquired1}"
report "first acquire exits 0"          "0"   "${rc1}"

# Second runner should NOT have acquired and should have exited 0
# (the spec says exit 0 — graceful no-op for concurrent fire).
if grep -q '^ACQUIRED$' "${tmpdir_a}/out2"; then
  acquired2="yes"
else
  acquired2="no"
fi
report "second concurrent acquire is rejected" "no" "${acquired2}"
report "second concurrent acquire exits 0"     "0"  "${rc2}"

# After both runners finish, the EXIT trap on the first runner should have
# removed the lock dir.
if [[ -d "${tmpdir_a}/sync.lock" ]]; then
  lock_dir_after="present"
else
  lock_dir_after="absent"
fi
report "EXIT trap releases lock dir" "absent" "${lock_dir_after}"

rm -rf "${tmpdir_a}"

# ---------------------------------------------------------------------------
# Case B: A lock dir mtime'd >600s in the past is broken and re-acquired.
# ---------------------------------------------------------------------------
tmpdir_b=$(mktemp -d -t hither-lock-b.XXXXXX)
runner_b="${tmpdir_b}/runner.zsh"
make_runner "${tmpdir_b}" "${runner_b}"

mkdir "${tmpdir_b}/sync.lock"
# Backdate the lock dir's mtime to 700s in the past — well past the 600s TTL.
touch -t "$(date -v-700S +%Y%m%d%H%M.%S)" "${tmpdir_b}/sync.lock"

HOLD_SECS=0 "${runner_b}" > "${tmpdir_b}/out" 2>&1
rc=$?

if grep -q '^ACQUIRED$' "${tmpdir_b}/out"; then
  acquired_stale="yes"
else
  acquired_stale="no"
fi
report "stale lock (>600s) is broken and re-acquired" "yes" "${acquired_stale}"
report "post-stale-break acquire exits 0"             "0"   "${rc}"

rm -rf "${tmpdir_b}"

# ---------------------------------------------------------------------------
# Case C: HITHER_SKIP_LOCK=1 disables the lock entirely.
# Verifies the test-only escape hatch still works (we don't want the
# escape hatch to silently break and have tests start tripping on the real
# user lock).
# ---------------------------------------------------------------------------
tmpdir_c=$(mktemp -d -t hither-lock-c.XXXXXX)
runner_c="${tmpdir_c}/runner.zsh"
make_runner "${tmpdir_c}" "${runner_c}"

# Pre-populate a fresh (not stale) lock dir to prove the skip path doesn't
# even look at it.
mkdir "${tmpdir_c}/sync.lock"

HITHER_SKIP_LOCK=1 HOLD_SECS=0 "${runner_c}" > "${tmpdir_c}/out" 2>&1
rc=$?

if grep -q '^ACQUIRED$' "${tmpdir_c}/out"; then
  acquired_skip="yes"
else
  acquired_skip="no"
fi
report "HITHER_SKIP_LOCK=1 bypasses lock check" "yes" "${acquired_skip}"
report "skip-path acquire exits 0"              "0"   "${rc}"

# The skip path doesn't touch the pre-existing lock dir; clean up by hand.
rm -rf "${tmpdir_c}"

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
