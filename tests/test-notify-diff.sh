#!/bin/zsh
# SPDX-License-Identifier: MIT
# tests/test-notify-diff.sh — isolated unit tests for the v0.5
# share-set diff + change-summary logic in libexec/hither-sync.sh.
#
# Does NOT exercise the network/DSM/Keychain/sudo path. Sources the
# sync script's helper functions and feeds them controlled inputs.
#
# Run: zsh tests/test-notify-diff.sh
# Exit: 0 on all-pass; 1 on any failure.

set -uo pipefail

HERE="${0:A:h}"
PROJECT_ROOT="${HERE:h}"

# We can't `source` hither-sync.sh directly — it has top-level code that
# initializes logging and exits if NAS_LIST isn't reachable. Instead,
# we copy out the two pure functions we want to test via awk.

# Extract a single function definition from a zsh script. Args: <file> <func>.
extract_function() {
  local file="$1" func="$2"
  awk -v f="$func" '
    $0 ~ "^"f"\\(\\)[[:space:]]*\\{" { in_fn = 1 }
    in_fn { print }
    in_fn && $0 ~ /^}/ { exit }
  ' "$file"
}

SYNC_SH="${PROJECT_ROOT}/libexec/hither-sync.sh"
[[ -f "${SYNC_SH}" ]] || { echo "FATAL: ${SYNC_SH} not found"; exit 1; }

# Eval the helper functions into this shell.
eval "$(extract_function "${SYNC_SH}" extract_share_set_from_map)"
eval "$(extract_function "${SYNC_SH}" compute_change_summary)"

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
# Test 1: extract_share_set_from_map — parses real map-body format
# ---------------------------------------------------------------------------
echo "== extract_share_set_from_map =="

read -r -d '' MAP_BODY_A <<'MAP' || true
# /etc/hither_mynas — AutoFS indirect map.
# MANAGED BY hither sync — DO NOT EDIT BY HAND.
# Generated: 2026-05-20T08:00:00-0400
# Target user: me
# Format: <share-key>  -fstype=smbfs,soft  ://<user>@<host>/<share>

Documents                                          -fstype=smbfs,soft ://me@mynas/Documents
Media                                              -fstype=smbfs,soft ://me@mynas/Media
Photos                                             -fstype=smbfs,soft ://me@mynas/Photos
MAP

expected=$'Documents\nMedia\nPhotos'
actual="$(printf '%s\n' "${MAP_BODY_A}" | extract_share_set_from_map)"
report "extracts 3 shares from real map body" "${expected}" "${actual}"

# Empty / blank input → empty output.
actual="$(printf '' | extract_share_set_from_map)"
report "empty input → empty output" "" "${actual}"

# Comments-only input → empty output.
actual="$(printf '# comment 1\n# comment 2\n\n' | extract_share_set_from_map)"
report "comments-only input → empty output" "" "${actual}"

# ---------------------------------------------------------------------------
# Test 2: compute_change_summary — combinatorial cases
# ---------------------------------------------------------------------------
echo "== compute_change_summary =="

tmpdir=$(mktemp -d -t hither-test.XXXXXX)
trap "rm -rf ${tmpdir}" EXIT

# Helper: make_files <added-list> <removed-list>; prints "<added-file> <removed-file>"
make_files() {
  local added="$1" removed="$2"
  printf '%s' "${added}" > "${tmpdir}/added"
  printf '%s' "${removed}" > "${tmpdir}/removed"
  printf '%s %s\n' "${tmpdir}/added" "${tmpdir}/removed"
}

# Case: both empty → empty summary
read added removed <<< "$(make_files '' '')"
report "both empty → empty summary" "" "$(compute_change_summary "${added}" "${removed}")"

# Case: +1 added, 0 removed
read added removed <<< "$(make_files $'Photos\n' '')"
report "+1 added → '+ Photos'" "+ Photos" "$(compute_change_summary "${added}" "${removed}")"

# Case: 0 added, 1 removed
read added removed <<< "$(make_files '' $'OldShare\n')"
expected_removed='− OldShare'
report "1 removed → '− OldShare'" "${expected_removed}" "$(compute_change_summary "${added}" "${removed}")"

# Case: 2 added, 1 removed (total 3, still enumerable)
read added removed <<< "$(make_files $'Photos\nVideos\n' $'OldShare\n')"
expected='+ Photos, Videos / − OldShare'
report "2 added + 1 removed → enumerated" "${expected}" "$(compute_change_summary "${added}" "${removed}")"

# Case: 5 added, 2 removed (total 7, numeric summary)
read added removed <<< "$(make_files $'A\nB\nC\nD\nE\n' $'X\nY\n')"
expected='+ 5 new, − 2 removed'
report "5+2 → numeric summary" "${expected}" "$(compute_change_summary "${added}" "${removed}")"

# Case: 4 added, 0 removed (total 4, numeric — boundary is >3)
read added removed <<< "$(make_files $'A\nB\nC\nD\n' '')"
expected='+ 4 new, − 0 removed'
report "4 added → numeric (boundary)" "${expected}" "$(compute_change_summary "${added}" "${removed}")"

# Case: 1 added, 1 removed (total 2, enumerable)
read added removed <<< "$(make_files $'Photos\n' $'OldShare\n')"
expected='+ Photos / − OldShare'
report "1+1 → both enumerated with slash sep" "${expected}" "$(compute_change_summary "${added}" "${removed}")"

# ---------------------------------------------------------------------------
# Test 3: integration — full diff against two synthetic maps
# ---------------------------------------------------------------------------
echo "== full diff against two synthetic maps =="

read -r -d '' MAP_CURRENT <<'MAP' || true
# /etc/hither_test
Alpha   -fstype=smbfs,soft ://me@test/Alpha
Beta    -fstype=smbfs,soft ://me@test/Beta
Gamma   -fstype=smbfs,soft ://me@test/Gamma
OldFoo  -fstype=smbfs,soft ://me@test/OldFoo
MAP

read -r -d '' MAP_DESIRED <<'MAP' || true
# /etc/hither_test
Alpha    -fstype=smbfs,soft ://me@test/Alpha
Beta     -fstype=smbfs,soft ://me@test/Beta
Gamma    -fstype=smbfs,soft ://me@test/Gamma
NewBar   -fstype=smbfs,soft ://me@test/NewBar
NewBaz   -fstype=smbfs,soft ://me@test/NewBaz
MAP

current_set="${tmpdir}/integration_current"
desired_set="${tmpdir}/integration_desired"
added_set="${tmpdir}/integration_added"
removed_set="${tmpdir}/integration_removed"

printf '%s\n' "${MAP_CURRENT}" | extract_share_set_from_map > "${current_set}"
printf '%s\n' "${MAP_DESIRED}" | extract_share_set_from_map > "${desired_set}"
comm -13 "${current_set}" "${desired_set}" > "${added_set}"
comm -23 "${current_set}" "${desired_set}" > "${removed_set}"

actual_added="$(tr '\n' ',' < "${added_set}" | sed 's/,$//')"
report "integration: added set" "NewBar,NewBaz" "${actual_added}"

actual_removed="$(tr '\n' ',' < "${removed_set}" | sed 's/,$//')"
report "integration: removed set" "OldFoo" "${actual_removed}"

summary="$(compute_change_summary "${added_set}" "${removed_set}")"
report "integration: summary" "+ NewBar, NewBaz / − OldFoo" "${summary}"

# ---------------------------------------------------------------------------
# Test 4: no-change scenario (file body churns, share-set stable)
# ---------------------------------------------------------------------------
echo "== no-change scenario =="

read -r -d '' MAP_BEFORE <<'MAP' || true
# Generated: 2026-05-19T04:23:00-0400
Alpha   -fstype=smbfs,soft ://me@test/Alpha
Beta    -fstype=smbfs,soft ://me@test/Beta
MAP

read -r -d '' MAP_AFTER <<'MAP' || true
# Generated: 2026-05-20T04:23:00-0400
Alpha   -fstype=smbfs,soft ://me@test/Alpha
Beta    -fstype=smbfs,soft ://me@test/Beta
MAP

printf '%s\n' "${MAP_BEFORE}" | extract_share_set_from_map > "${tmpdir}/nc_before"
printf '%s\n' "${MAP_AFTER}"  | extract_share_set_from_map > "${tmpdir}/nc_after"
comm -13 "${tmpdir}/nc_before" "${tmpdir}/nc_after" > "${tmpdir}/nc_added"
comm -23 "${tmpdir}/nc_before" "${tmpdir}/nc_after" > "${tmpdir}/nc_removed"

actual_summary="$(compute_change_summary "${tmpdir}/nc_added" "${tmpdir}/nc_removed")"
report "timestamp churn but stable set → empty summary" "" "${actual_summary}"

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
