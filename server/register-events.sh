#!/usr/bin/env bash
# Register / update per-host hither-sync events from
# hither-sync.manifest.json.
#
# Idempotent: looks each event up by title, creates if missing, updates if
# present. Default mode is DRY RUN — prints the plan without calling the
# xyOps create/update APIs.
#
# WHAT THIS DOES (one event per Mac under category "AutoFS Share Map Sync"):
#   - For each host in the manifest's `hosts` array:
#     - Event title:  hither-sync-<name>
#     - Category:     "AutoFS Share Map Sync"
#     - Target:       the host's xysat server_id (per-event, NOT category default)
#     - Plugin:       shellplug
#     - Triggers:     manual + schedule (daily 04:<schedule_minute> ET — low-priority window per manifest)
#     - Catch-up:     true — Mac asleep at fire time runs on next reconnect,
#                     no failure ticket, no missed run
#     - Params:       { script: <wrapper that curls hither-sync.sh from
#                       Forgejo at pinned SHA, exports TARGET_USER + NAS_LIST,
#                       execs the script as the xysat user (infra-agent)> }
#     - Actions:      empty by default; ticket-on-failure wired if --with-tickets.
#                     ticket-on-failure dedups by source_event_<id> so each host's
#                     real failures (auth, sudo, DSM unreachable) get distinct tickets.
#   - After all events are upserted, the forgejo-ro-admin-technical secret
#     is updated to assign to all per-host event IDs.
#
# DIFFERENCES FROM register-dump-installed-software-events.sh:
#   - No sudo-to-target-user step in the wrapper. hither-sync.sh runs as the
#     xysat user (infra-agent) and uses NOPASSWD sudo internally for narrow
#     tasks (`tee /etc/hither_*`, `automount -cv`) per
#     /etc/sudoers.d/xysat-hither-sync.
#   - Per-host env vars: TARGET_USER (DSM user), NAS_LIST (space-sep), NAS_PROTO,
#     OP_VAULT — read by hither-sync.sh from environment.
#   - Schedule window is daily 04:<minute> ET (manifest's morning-low-priority
#     preset) — share lists change rarely so high cadence has no payoff.
#
# WORKFLOW:
#   1. Edit ~/admin-technical/setup/synology/xyops/jobs/hither-sync.{sh,manifest.json}
#   2. git commit + git push umbridge main  (Pattern #2: SHA must be on Forgejo)
#   3. ./register-hither-sync-events.sh                # dry-run, see plan
#   4. ./register-hither-sync-events.sh --apply        # create/update events
#   5. (Verify a manual run on each host — Run Now from the xyOps UI)
#   6. ./register-hither-sync-events.sh --apply --with-tickets
#                                                       # wire failure tickets
#
# FLAGS:
#   --apply             Actually call create_event/update_event APIs (default: dry-run)
#   --only=<name>       Only process hosts matching this name (substring)
#   --with-tickets      Wire ticket-on-failure on each event (run after green window)
#   --no-secret-sync    Skip updating forgejo-ro-admin-technical secret assignments
#
# OFFLINE-HANDLING DESIGN: same as dump-installed-software — catch_up:true means
# asleep/unreachable Macs queue silently and run on next reconnect, no ticket.
#
# PER-HOST PREREQUISITES (must hold before --apply succeeds operationally):
#   1. /etc/sudoers.d/xysat-hither-sync installed (see sudoers/xysat-hither-sync).
#   2. 1Password item `<nas> - DSM - <target_user_dsm> (Login)` exists in vault `JRVIS Infra` for each NAS in nas_list. Account MUST NOT have 2FA enabled.
#   3. `op` CLI authenticated for the xysat run-as user (infra-agent).
#   4. /etc/auto_master has the `/Hither/<nas> hither_<nas> -nosuid` line for each NAS in nas_list (run setup-autofs-<nas>.sh once if not).
#
# Verify with:
#   ssh infra-agent@<host> "sudo -n /usr/sbin/automount -cv >/dev/null 2>&1 && echo SUDO_OK"
#   ssh infra-agent@<host> "op whoami"
#   ssh infra-agent@<host> "op item get '<nas> - DSM - <target_user_dsm> (Login)' --vault 'JRVIS Infra' --fields password --reveal | head -c 4"
#
# Requirements: 1Password CLI authenticated, jq, curl, git.

set -euo pipefail

# --- Parse flags ---

DRY_RUN=1
ONLY=""
WITH_TICKETS=0
SKIP_SECRET=0
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) DRY_RUN=0 ;;
    --only=*) ONLY="${1#--only=}" ;;
    --with-tickets) WITH_TICKETS=1 ;;
    --no-secret-sync) SKIP_SECRET=1 ;;
    -h|--help)
      sed -n '2,68p' "$0"
      exit 0
      ;;
    *) echo "ERROR: unknown flag: $1" >&2; exit 64 ;;
  esac
  shift
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MANIFEST="${SCRIPT_DIR}/hither-sync.manifest.json"
CANONICAL_SCRIPT_REL="server/hither-sync.sh"
XYOPS_BASE="${XYOPS_BASE:-http://umbridge:5522}"
FORGEJO_BASE="${FORGEJO_BASE:-http://umbridge:8914}"
# Mac xysats reach Forgejo over Tailscale (they aren't sibling-Docker on
# Umbridge). Use the FQDN; works on or off the home LAN.
FORGEJO_BASE_MAC="${FORGEJO_BASE_MAC:-http://umbridge.tail486ac0.ts.net:8914}"
REPO_OWNER="dev"
REPO_NAME="hither"
SECRET_VAR_NAME="FORGEJO_RO_TOKEN_HITHER"
SECRET_TITLE="forgejo-ro-hither"
CATEGORY_TITLE="$(jq -r '.category_title' "$MANIFEST")"
CATEGORY_DESCRIPTION="$(jq -r '.category_description // ""' "$MANIFEST")"
CATEGORY_NOTES="$(jq -r '.category_notes // ""' "$MANIFEST")"
ERROR_RUN_EVENTS_JSON="$(jq -c '.error_run_events // []' "$MANIFEST")"

if [ ! -f "$MANIFEST" ]; then
  echo "ERROR: manifest not found at $MANIFEST" >&2
  exit 1
fi

# --- Resolve repo SHA + verify pushed to Forgejo ---

cd "$SCRIPT_DIR"
SHA=$(git rev-parse HEAD)
echo "Pinning to admin-technical HEAD: $SHA"

if ! git diff --quiet HEAD -- "$SCRIPT_DIR/hither-sync.sh" "$MANIFEST" 2>/dev/null; then
  echo "WARNING: hither-sync.sh or manifest has uncommitted changes — wrappers will use last committed SHA $SHA." >&2
  echo "         Commit + push before running with --apply." >&2
fi

FG_TOK=$(op item get "Forgejo - Umbridge - xyops-readonly" \
  --vault "JRVIS Infra" --fields password --reveal 2>/dev/null | tr -d '\n ')
if [ -z "$FG_TOK" ]; then
  echo "ERROR: failed to read 'Forgejo - Umbridge - xyops-readonly' from 1Password" >&2
  exit 1
fi

VERIFY_URL="${FORGEJO_BASE}/${REPO_OWNER}/${REPO_NAME}/raw/commit/${SHA}/${CANONICAL_SCRIPT_REL}"
VERIFY_CODE=$(curl -sS -o /dev/null -w '%{http_code}' \
  -H "Authorization: token $FG_TOK" --max-time 10 "$VERIFY_URL")
if [ "$VERIFY_CODE" != "200" ] && [ "$DRY_RUN" -eq 0 ]; then
  echo "ERROR: Forgejo returned HTTP $VERIFY_CODE for $VERIFY_URL" >&2
  echo "       SHA $SHA isn't pushed to umbridge remote yet. Run: git push umbridge main" >&2
  exit 3
fi
if [ "$VERIFY_CODE" = "200" ]; then
  echo "Verified canonical script reachable on Forgejo at SHA $SHA"
else
  echo "WARNING (dry-run): canonical script not yet on Forgejo (HTTP $VERIFY_CODE) — push before --apply"
fi

# --- Login to xyOps ---

XYOPS_PASS=$(op item get "xyOps - Umbridge - admin (Login)" \
  --vault "JRVIS Infra" --fields password --reveal 2>/dev/null)
if [ -z "$XYOPS_PASS" ]; then
  echo "ERROR: failed to read xyOps admin password from 1Password" >&2
  exit 1
fi

COOKIE=$(mktemp); LOGIN=$(mktemp); RESP=$(mktemp)
trap 'rm -f "$COOKIE" "$LOGIN" "$RESP"' EXIT

curl -sf -c "$COOKIE" -X POST "${XYOPS_BASE}/api/user/login" \
  -H "Content-Type: application/json" \
  -d "$(jq -n --arg p "$XYOPS_PASS" '{username:"admin",password:$p}')" \
  -o "$LOGIN" >/dev/null
CSRF=$(jq -r '.csrf_token' < "$LOGIN")

xyops_call() {
  # xyops_call <endpoint> <body-json> → response in $RESP
  local endpoint="$1" body="$2"
  curl -sf -b "$COOKIE" -H "X-CSRF-Token: $CSRF" \
    -X POST "${XYOPS_BASE}/api/app/${endpoint}/v1" \
    -H "Content-Type: application/json" --data "$body" -o "$RESP"
}

# --- Resolve category id ---
CATEGORY_ID=$(jq -r --arg t "$CATEGORY_TITLE" '.categories[]? | select(.title == $t) | .id' < "$LOGIN" | head -1)
if [ -z "$CATEGORY_ID" ]; then
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "Category '$CATEGORY_TITLE' does not exist yet — would create on --apply."
    CATEGORY_ID="<would-be-created>"
  else
    echo "Creating category: $CATEGORY_TITLE"
    # Newly-created categories default to enabled:false in xyOps — events
    # in a disabled category fail to launch with "Category is disabled".
    # Always explicitly enable.
    xyops_call "create_category" "$(jq -nc \
      --arg t "$CATEGORY_TITLE" \
      --arg d "$CATEGORY_DESCRIPTION" \
      --arg n "$CATEGORY_NOTES" \
      '{title:$t, description:$d, notes:$n, enabled:true, max_children:0, notify_success:"", notify_fail:""}')"
    CATEGORY_ID=$(jq -r '.id // .category.id // ""' < "$RESP")
    if [ -z "$CATEGORY_ID" ] || [ "$CATEGORY_ID" = "null" ]; then
      echo "ERROR: create_category returned no id: $(cat "$RESP" | head -c 300)" >&2
      exit 1
    fi
    echo "  → created category: $CATEGORY_ID"
  fi
else
  echo "Resolved category: $CATEGORY_TITLE -> $CATEGORY_ID"
fi

# --- Build wrapper body for one host ---
# The wrapper:
#   1. Asserts the Forgejo readonly token is injected (xyOps secret).
#   2. Curls the canonical hither-sync.sh from Forgejo at pinned SHA.
#   3. Exports TARGET_USER + NAS_LIST + NAS_PROTO + OP_VAULT, execs the script.
#      (No sudo step — hither-sync.sh runs as the xysat user, uses NOPASSWD
#      sudo internally for narrow ops via /etc/sudoers.d/xysat-hither-sync.)
build_wrapper() {
  local name="$1" target_user_dsm="$2" nas_list="$3"
  jq -nr \
    --arg sha "$SHA" \
    --arg name "$name" \
    --arg user "$target_user_dsm" \
    --arg nas_list "$nas_list" \
    --arg url "${FORGEJO_BASE_MAC}/${REPO_OWNER}/${REPO_NAME}/raw/commit/${SHA}/${CANONICAL_SCRIPT_REL}" \
    --arg secret "$SECRET_VAR_NAME" \
    '
    "#!/usr/bin/env bash\n" +
    "# WRAPPER (xyOps event \"hither-sync-" + $name + "\") — Pattern #2: fetch canonical script from Forgejo at pinned SHA.\n" +
    "#\n" +
    "# Canonical script: infra/admin-technical@" + $sha + ":" + "setup/synology/xyops/jobs/hither-sync.sh\n" +
    "# Updated by: setup/synology/xyops/jobs/register-hither-sync-events.sh\n" +
    "# Token source: xyOps secret '\''forgejo-ro-admin-technical'\'' → env " + $secret + "\n" +
    "# Target DSM user: " + $user + "  |  NAS list: " + $nas_list + "\n" +
    "#\n" +
    "# To deploy a new version: edit ~/admin-technical/setup/synology/xyops/jobs/hither-sync.sh OR hither-sync.manifest.json,\n" +
    "# commit, `git push umbridge main`, then `./register-hither-sync-events.sh --apply`.\n" +
    "set -euo pipefail\n" +
    ": \"${" + $secret + ":?Required xyOps secret '\''" + $secret + "'\'' missing — assign forgejo-ro-admin-technical to this event.}\"\n" +
    "# Tempfile + shebang exec pattern (per dump-installed-software wrapper notes):\n" +
    "# zsh -c $SCRIPT_BODY proved unreliable under xysat exec context.\n" +
    "TMP=$(mktemp /tmp/hither-sync.XXXXXX)\n" +
    "curl -fsSL --max-time 30 \\\n" +
    "  -H \"Authorization: token ${" + $secret + "}\" \\\n" +
    "  \"" + $url + "\" > \"$TMP\"\n" +
    "chmod 0755 \"$TMP\"\n" +
    "export TARGET_USER=" + ($user | @sh) + "\n" +
    "export NAS_LIST=" + ($nas_list | @sh) + "\n" +
    "exec \"$TMP\"\n"
    '
}

# --- Build triggers array ---
# Daily schedule at hour 4 (low-priority window per manifest preset), per-host
# minute. Plus manual trigger so the UI "Run Now" button works.
build_triggers() {
  local minute="$1"
  jq -nc \
    --argjson minute "$minute" \
    '[
      {type:"manual",   enabled:true},
      {type:"schedule", enabled:true, hours:[4], minutes:[$minute]}
    ]'
}

# --- Build actions array per event ---
build_event_actions() {
  if [ "$WITH_TICKETS" -eq 1 ]; then
    jq -nc --argjson runs "$ERROR_RUN_EVENTS_JSON" \
      '[$runs[] | {enabled:true, condition:"error", type:"run_event", event_id:.}]'
  else
    echo '[]'
  fi
}

# --- Sync category description + notes from manifest ---
if [ "$CATEGORY_ID" != "<would-be-created>" ]; then
  xyops_call "get_category" "$(jq -nc --arg id "$CATEGORY_ID" '{id:$id}')"
  CURRENT_DESCRIPTION=$(jq -r '.category.description // ""' < "$RESP")
  CURRENT_NOTES=$(jq -r '.category.notes // ""' < "$RESP")
  if [ "$CURRENT_DESCRIPTION" != "$CATEGORY_DESCRIPTION" ] || [ "$CURRENT_NOTES" != "$CATEGORY_NOTES" ]; then
    if [ "$DRY_RUN" -eq 1 ]; then
      echo "Category description/notes drift detected (would update on --apply)."
    else
      echo "Syncing category description + notes"
      xyops_call "update_category" "$(jq -nc \
        --arg id "$CATEGORY_ID" \
        --arg desc "$CATEGORY_DESCRIPTION" \
        --arg notes "$CATEGORY_NOTES" \
        '{id:$id, description:$desc, notes:$notes}')"
    fi
  else
    echo "Category description+notes in sync."
  fi
fi

# --- Iterate the manifest hosts ---

echo
if [ "$DRY_RUN" -eq 1 ]; then
  echo "=== DRY RUN — no changes will be applied ==="
else
  echo "=== APPLYING — creating/updating xyOps events ==="
fi
echo "  Category:       $CATEGORY_TITLE ($CATEGORY_ID)"
echo "  Tickets wired:  $( [ "$WITH_TICKETS" -eq 1 ] && echo "yes (per-event run_event → ticket-on-failure)" || echo "no (use --with-tickets after green window)" )"
echo "  Filter:         $( [ -n "$ONLY" ] && echo "$ONLY" || echo "(all)" )"
echo

TOUCHED_EVENT_IDS=()

HOSTS_JSON=$(jq -c '.hosts[]' "$MANIFEST")
while IFS= read -r host; do
  name=$(jq -r '.name' <<<"$host")
  server_id=$(jq -r '.target_server_id' <<<"$host")
  target_user_dsm=$(jq -r '.target_user_dsm' <<<"$host")
  nas_list=$(jq -r '.nas_list' <<<"$host")
  schedule_minute=$(jq -r '.schedule_minute' <<<"$host")
  note=$(jq -r '.note // ""' <<<"$host")
  title="hither-sync-${name}"

  if [ -n "$ONLY" ] && [[ "$name" != *"$ONLY"* ]]; then
    continue
  fi

  # Validate target_server_id — TBD placeholders are a hard error on --apply.
  if [[ "$server_id" == TBD-* ]] || [ -z "$server_id" ] || [ "$server_id" = "null" ]; then
    if [ "$DRY_RUN" -eq 0 ]; then
      echo "ERROR: host '$name' has unresolved target_server_id ('$server_id'). Look up the xysat ID via xyOps API and update the manifest before --apply." >&2
      exit 4
    else
      echo "[SKIP]  $title  (target_server_id=$server_id — needs lookup before --apply)"
      continue
    fi
  fi

  existing_id=$(jq -r --arg t "$title" '.events[]? | select(.title == $t) | .id' < "$LOGIN" | head -1)

  wrapper=$(build_wrapper "$name" "$target_user_dsm" "$nas_list")
  triggers=$(build_triggers "$schedule_minute")
  actions=$(build_event_actions)

  if [ -n "$existing_id" ]; then
    action_label="UPDATE"
  else
    action_label="CREATE"
  fi

  printf '%-7s %s  target=%s  user=%s  nas=%s  schedule=04:%02d\n' \
    "[$action_label]" "$title" "$server_id" "$target_user_dsm" "$nas_list" "$schedule_minute"

  if [ "$DRY_RUN" -eq 1 ]; then
    [ -n "$existing_id" ] && TOUCHED_EVENT_IDS+=("$existing_id")
    continue
  fi

  # Right-sized limits: hither-sync is short-lived (DSM API + per-share
  # permission queries + diff + maybe sudo write/automount). Tighter than
  # dump-installed-software because no per-share heavy work.
  # job=1 (no concurrent runs), queue=0 (excess triggers aborted),
  # time=300s wall-clock, mem=256 MiB peak sustained 30s.
  limits=$(jq -nc '[
    {type:"job",   enabled:true, amount:1},
    {type:"queue", enabled:true, amount:0},
    {type:"time",  enabled:true, duration:300, abort:true},
    {type:"mem",   enabled:true, amount:268435456, duration:30, abort:true}
  ]')

  if [ -z "$existing_id" ]; then
    # CREATE
    body=$(jq -n \
      --arg t "$title" \
      --arg cat "$CATEGORY_ID" \
      --arg tgt "$server_id" \
      --arg note "$note" \
      --arg w "$wrapper" \
      --argjson triggers "$triggers" \
      --argjson actions "$actions" \
      --argjson limits "$limits" \
      '{
         title: $t,
         category: $cat,
         targets: [$tgt],
         enabled: true,
         catch_up: true,
         algo: "random",
         plugin: "shellplug",
         params: {script: $w},
         triggers: $triggers,
         actions: $actions,
         limits: $limits,
         notes: ("Auto-generated by register-hither-sync-events.sh from hither-sync.manifest.json. " + $note)
       }')
    xyops_call "create_event" "$body"
    new_id=$(jq -r '.id // .event.id // ""' < "$RESP")
    if [ -z "$new_id" ] || [ "$new_id" = "null" ]; then
      echo "  ERROR: create_event returned no id: $(cat "$RESP" | head -c 300)" >&2
      continue
    fi
    echo "  → created: $new_id"
    TOUCHED_EVENT_IDS+=("$new_id")
  else
    # UPDATE
    body=$(jq -n \
      --arg id "$existing_id" \
      --arg cat "$CATEGORY_ID" \
      --arg tgt "$server_id" \
      --arg note "$note" \
      --arg w "$wrapper" \
      --argjson triggers "$triggers" \
      --argjson actions "$actions" \
      --argjson limits "$limits" \
      '{
         id: $id,
         category: $cat,
         targets: [$tgt],
         catch_up: true,
         params: {script: $w},
         triggers: $triggers,
         actions: $actions,
         limits: $limits,
         notes: ("Auto-generated by register-hither-sync-events.sh from hither-sync.manifest.json. " + $note)
       }')
    xyops_call "update_event" "$body"
    rev=$(jq -r '.event.revision // "?"' < "$RESP")
    echo "  → updated: $existing_id (rev=$rev)"
    TOUCHED_EVENT_IDS+=("$existing_id")
  fi
done <<<"$HOSTS_JSON"

# --- Sync forgejo-ro-admin-technical secret to assign all touched events ---

if [ "$DRY_RUN" -eq 0 ] && [ "$SKIP_SECRET" -eq 0 ] && [ ${#TOUCHED_EVENT_IDS[@]} -gt 0 ]; then
  echo
  echo "=== Syncing $SECRET_TITLE secret assignments ==="
  SECRET_ID=$(jq -r --arg t "$SECRET_TITLE" '.secrets[]? | select(.title == $t) | .id' < "$LOGIN" | head -1)
  if [ -z "$SECRET_ID" ]; then
    echo "WARNING: secret '$SECRET_TITLE' not found in xyOps — events will fail until secret is assigned." >&2
  else
    EXISTING_EVENTS_JSON=$(jq --arg t "$SECRET_TITLE" -c '.secrets[] | select(.title == $t) | .events // []' < "$LOGIN")
    NEW_EVENTS_JSON=$(printf '%s\n' "${TOUCHED_EVENT_IDS[@]}" | jq -R . | jq -s .)
    MERGED=$(jq -c -n --argjson a "$EXISTING_EVENTS_JSON" --argjson b "$NEW_EVENTS_JSON" '($a + $b) | unique')
    xyops_call "update_secret" "$(jq -n --arg id "$SECRET_ID" --argjson events "$MERGED" \
      '{id:$id, events:$events}')"
    echo "  → secret $SECRET_ID now assigned to $(jq 'length' <<<"$MERGED") events"
  fi
fi

echo
if [ "$DRY_RUN" -eq 1 ]; then
  echo "DRY RUN complete. Re-run with --apply to execute."
else
  echo "Done. Touched ${#TOUCHED_EVENT_IDS[@]} event(s)."
fi
