# Changelog

## [0.5.2] — 2026-05-20

Iterative-verification round-2 fixes. Round 2 ran 3 verifiers in parallel against v0.5.1; all 5 round-1 doc fixes were confirmed landed, all 7 round-1 notification code-path fixes were confirmed landed, all 4 v0.4.1 fixes were confirmed intact, the test-suite gaps were closed. Round 2 surfaced one warning (this release) plus 3 low-severity cosmetic nits (deferred).

### Fixed
- **`bin/hither` inline `--help` text for `hither sync`** was stale after the v0.5.1 cmd_sync any-true OR-aggregation. The help string said "default is to read the first subscription's notify_on_changes" — the code had been changed to OR-aggregate across all subscriptions. The text now matches the code: "default is the any-true OR-aggregation across all subscriptions (matches the scheduled LaunchAgent's behavior)." Also: the sync help now lists all four `--notify` flag forms (`--notify` / `--no-notify` / `--notify=true` / `--notify=false`) for parity with the README CLI table.
- **`.github/workflows/ci.yml`** — pinned `ludeeus/action-shellcheck` from `@master` to the v2.0.0 release sha (`00cae500b08a931fb5698e11e79bfbd38e612a38`). Removes the reproducibility risk of a floating-tag dependency on a third-party Action.

### Accepted nits (deliberately not fixed)
- Test-fixture `schedule_hour = 4` / `schedule_minute = 23` values inlined in `tests/test-notify-diff.sh` and `tests/test-launchagent-env.sh` stub TOMLs. Test fixtures are not load-bearing config; inline is reasonable.
- The `trap "rm -rf ${tmpdir}" EXIT` in `tests/test-launchagent-env.sh` is overwritten across cases — in practice the failure window is empty (each case sets its own trap before doing anything destructive), so this is a cosmetic robustness note rather than a real bug.

### Version
- `bin/hither` `HITHER_VERSION` → `0.5.2`
- `Formula/hither.rb` `version` → `0.5.2`

## [0.5.1] — 2026-05-20

Iterative-verification round-1 fixes on v0.5.0. All bugs caught before publication.

### Fixed
- **`tests/test-notify-diff.sh` silently no-op'd under bash.** The shebang says `#!/bin/zsh` but a contributor running `bash tests/test-notify-diff.sh` would see `${0:A:h}: unbound variable` at line 14 (a zsh-only modifier expansion), then exit 0 — a green light that didn't actually run anything. Added an explicit shell-guard that fails loudly when invoked under non-zsh. **Publication-blocker fix.**
- **`fire_notification` AppleScript escape pass missed `$` and backtick.** AppleScript double-quoted string literals interpolate `\\`, `\"`, `\$`, and `` \` ``. The previous escape covered only the first two. Defensive — share names are bounded by DSM validation, but cheap insurance against a future-self foot-gun. **Publication-blocker fix.**
- **`fire_notification` could hang the sync if Notification Center is wedged.** Wrapped the osascript invocation in `perl -e 'alarm 5; exec @ARGV' ...` (subshell-isolated) so a hung NC times out at 5 seconds rather than indefinitely. perl ships with macOS; no new dep. **Publication-blocker fix.**
- **`bin/hither sync` HITHER_NOTIFY default disagreed with the LaunchAgent.** A manual `hither sync` (no flags) used the FIRST subscription's `notify_on_changes`, but the LaunchAgent uses any-true OR-aggregated across subscriptions. Aligned: `cmd_sync` now also any-true OR-aggregates so a manual sync and a scheduled fire behave identically.
- **False "multibyte-safe" claim in `fire_notification` substr comment.** macOS BWK awk's `substr` is BYTE-indexed, not codepoint-indexed — the comment claimed otherwise. Rephrased the comment to be honest about the trade-off (truncate to 150 bytes, accept multi-byte glyph split at the boundary). Python3 is not guaranteed-present on macOS post-12.3, so we don't reach for it.

### Changed
- **README Status section** now reflects v0.5.0 share-set notifications (was still pinned at v0.4.0 polish).
- **README CLI table** documents both `--notify` / `--no-notify` and `--notify=true|false` flag forms for `subscribe` and `sync`. Previously only the `=` form was listed.
- **Plist `ServiceDescription` strings** (both bootstrap + sync) updated: "not renamed in v0.4.0" → "not renamed in the v0.x series" so the rationale doesn't read as version-specific.
- **`docs/architecture.md` TOML example** uses `hither_version = "<current>"` placeholder rather than hardcoding the current version.
- **`bin/hither` legacy-sudoers comments** annotated with "Legacy file from the pre-v0.2 centrally-scheduled era; remove if present" so future readers don't try to revive the xysat-hither-sync pathway.

### Added
- **`tests/test-launchagent-env.sh`** — closes the test-coverage gap from the iterative-verification test-exhaustiveness verifier. Five cases covering single-true / single-false / all-false / one-true (OR aggregation) / all-true. Asserts `plutil -lint` passes, `HITHER_NOTIFY` reflects OR-aggregation, and `NAS_LIST` / `TARGET_USER` are correctly substituted.
- **`tests/test-notify-diff.sh` Test 5** — exercises `fire_notification` in dry-run mode against a body containing `"`, `$VAR`, and `` ` ``. Captures the would-be osascript invocation and asserts each metachar is correctly escaped.
- **`extract_function` sanity check** — `tests/test-notify-diff.sh` now hard-fails with a clear error if `extract_share_set_from_map` / `compute_change_summary` / `fire_notification` aren't defined after eval, rather than silently no-op'ing.

### CI
- **`.github/workflows/ci.yml`** (renamed from `shellcheck.yml`) — adds a macOS job that runs both test suites. The shellcheck job remains as a parallel job. Tests need `plutil` and the bash + zsh stack; macos-latest runner has them.

### Known design quirk (intentional, post-v1.0 work)
- **`HITHER_NOTIFY` is a single global toggle, OR-aggregated across subscriptions.** All subs on one Mac share a single LaunchAgent, so a per-subscription notify gate would require per-NAS env injection we don't have. Consequence: a user upgrading from v0.4.x (existing sub stays at default-`false` per `hither_sub_read_notify`'s absent-field rule) and then adding ONE new sub (default `true`) will silently enable notifications for ALL their NASes on the next sync. If you have multiple subs and want per-NAS notification control, set each subscription's `notify_on_changes` consistently. Per-NAS notify is on the post-v1.0 roadmap. The TOML field is per-subscription (forward-compat) but the runtime gate is the global env var.

### Version
- `bin/hither` `HITHER_VERSION` → `0.5.1`
- `Formula/hither.rb` `version` → `0.5.1`

## [0.5.0] — 2026-05-20

Surface share-set changes as macOS notifications. Until now, the only way to find out that a NAS-side admin added or removed a share you can see was to hit `cd /Hither/<nas>/<share>` and get a "No such file" — or to manually `hither list` and notice the count drifting. v0.5 closes that gap with proactive notifications fired through `osascript`.

### Added
- **`notify_on_changes` field in `subscription.toml`.** New subscriptions default to `true`. Existing v0.4.x subscriptions that lack the field stay at default-`false` at read time, so this is opt-in for upgrades and opt-out for fresh installs.
- **`hither subscribe --notify=true|false` / `--notify` / `--no-notify`** CLI flag. Sets the field on subscription create.
- **`hither sync --notify` / `--no-notify`** CLI flag. One-shot override for a manual sync invocation; defaults to the first subscription's `notify_on_changes`.
- **`HITHER_NOTIFY` env var** wired into the LaunchAgent plist. Set to `1` iff ANY subscription has `notify_on_changes = true`. Refreshed on every `subscribe`/`unsubscribe` via `hither_refresh_launchagent_env`.
- **Share-set diff in `apply_map_if_changed`** in `libexec/hither-sync.sh`. Extracts share names from the on-disk map and the desired map, computes `added = desired - current` and `removed = current - desired` via `comm -13` / `comm -23`. When the membership differs (NOT just timestamp / whitespace churn), fires `osascript -e 'display notification "<summary>" with title "Hither — <nas>"'`. Wrapped in `|| true` — notification failure can never break the sync. Summary string is "+ Photos, Videos" / "− OldShare" / "+ Photos / − OldShare" for small diffs, "+ 5 new, − 2 removed" for larger ones. Capped at ~150 chars (multibyte-safe truncation via awk so the UTF-8 "−" minus sign doesn't get split).

### Skipped (intentional non-trigger paths)
- **Initial sync.** When there's no previous on-disk map, every share would show up as "added" — that's noise, not signal. The notification path is gated by an `is_initial` check.
- **No-op syncs.** When the share-set membership is identical to the on-disk map (even if the file body churned for some other reason), no notification fires. Logged as "share-set unchanged" in the sync log.
- **Opted-out subscriptions.** `HITHER_NOTIFY=0` → no `osascript` call.

### Design notes
- **Global, not per-subscription.** All subscriptions on one Mac share a single LaunchAgent; per-NAS notify-gating would require per-NAS env injection we don't have. Global toggle is fine for v0.5; per-NAS gate is a post-v1.0 nice-to-have. The TOML field is per-subscription (forward-compat for that future split) but the runtime gate is the global `HITHER_NOTIFY` env var.
- **No external dependency.** `osascript` ships with every macOS. No Homebrew `terminal-notifier` install. The notification appears in Notification Center under "Script Editor" (Apple's quirk — `display notification` is attributed to the AppleScript host).
- **Notification permission.** macOS may prompt for notification permission for "Script Editor" the first time. After that, notifications appear silently.

### Files changed
- `bin/hither` — version bump 0.4.1 → 0.5.0; `--notify` flag on `subscribe`; `--notify`/`--no-notify` flags on `sync`; HITHER_NOTIFY threaded to `hither-sync.sh` invocation
- `libexec/hither-lib.sh` — `notify_on_changes` field in `hither_sub_write`; `hither_sub_read_notify` helper; `HITHER_NOTIFY` env var in `hither_refresh_launchagent_env`
- `libexec/hither-sync.sh` — `extract_share_set_from_map`, `compute_change_summary`, `fire_notification` helpers; share-set diff in `apply_map_if_changed`
- `launchd/com.johnrandall.hither.sync.plist` — `HITHER_NOTIFY` key in `EnvironmentVariables`, default `0`
- `completions/hither.bash` — added `--notify` / `--no-notify` to `subscribe` and `sync`
- `Formula/hither.rb` — version 0.4.1 → 0.5.0
- `README.md`, `docs/architecture.md` — documented the notification path
- `tests/test-notify-diff.sh` — isolated diff/summary unit tests

### Version
- `bin/hither` `HITHER_VERSION` → `0.5.0`
- `Formula/hither.rb` `version` → `0.5.0`

## [0.4.1] — 2026-05-20

Iterative-verification fixes from the parallel verifier pass on v0.4.0. All bugs were caught BEFORE publication.

### Fixed
- **`hither uninstall` (no `--purge`) incorrectly suggested `--purge` for the root phase.** `${purge:+...}` expands when `purge` is set AND non-empty, and `purge=0` is non-empty, so the hint always read `sudo $(which hither) uninstall --purge` — which would have silently wiped subscription config and Keychain entries on a user who only asked to remove system files. Now explicitly tests `[[ "$purge" -eq 1 ]]` and prints the correct invocation. **Publication-blocker fix.**
- **`hither list` and `hither status` printed `0\n0` for zero shares / zero auto_master entries.** The pattern `$(grep -c ... || echo 0)` ran when grep exits 1 on no-match, but grep had also printed `0` on stdout — so command substitution captured `"0\necho-0"`. Replaced with `$(grep -c ... ) || var=0` (grep prints its own 0; we just guard against the exit-1).
- **`hither subscribe --user foo` (forgetting the positional NAS arg) reported "unknown arg to subscribe: u"** because `--user` was consumed as the NAS name and the shifter went on to parse `foo` as an unknown flag. Now rejects `--` -prefixed first args with a clear message.
- **`hither sync` on an unbootstrapped Mac told the user to run `sudo bootstrap`** when the more useful hint is "no subscriptions — run subscribe." Re-ordered the checks: empty-subscription state is now reported first; bootstrap-missing only surfaces when subscriptions exist but the system isn't installed.

### Documented
- **`docs/architecture.md`** — corrected two claims the architecture verifier flagged: (1) per-subscription `schedule_hour` / `schedule_minute` are NOT honored by the runtime (the LaunchAgent's `StartCalendarInterval` is fixed by the plist template; `hither_refresh_launchagent_env` only touches env vars), (2) softened the "catch-up on resume" language to make clear it's standard launchd behavior, not a Hither feature.

### Version
- `bin/hither` `HITHER_VERSION` → `0.4.1`
- `Formula/hither.rb` `version` → `0.4.1`

## [0.4.0] — 2026-05-20

Public-release polish pass. The repo is intended to flip from private to
public after this version lands. Every operator-facing file — README,
glossary, architecture, design-decisions, plist `ServiceDescription`
strings, comments in `libexec/hither-sync.sh` and `sbin/hither-write-map`
— has been audited to remove internal hostnames and internal-only
references. The architecture, CLI, and on-disk layout are unchanged.

### Privacy audit (per the `publish-pre-flight-audit` skill)

What changed:

- **README rewritten** for an audience that is *not* the author.
  Strangers-first framing: hero one-liner + concrete `ls` example,
  problem statement (autofs reverts, `/Network` clash, sudoers
  wildcards, Keychain duplication), Homebrew install path as the
  recommended way, manual install as the fallback, CLI surface as one
  reference table. Internal hostnames and the author's username are
  replaced with `<nas>` / `<dsm-user>` placeholders. The previous
  README's deep-internal context (Forgejo URLs, lash references in the
  install path) is gone.
- **`docs/glossary.md`** — dropped John-specific infrastructure terms
  (`xyOps`, `xysat`, `infra-agent`, `Umbridge`, `SusanBones`, `lash`).
  Kept the macOS-subsystem terms (autofs, automountd, synthetic.conf,
  apfs.util, SSV, Keychain, LaunchDaemon, LaunchAgent, WatchPaths) and
  added SMB / DSM / indirect-map definitions.
- **`docs/architecture.md`** — replaced the `umbridge` / `johntrandall`
  example values with `<nas>` / `<user>` placeholders in the sequence
  diagram and TOML example. The "No Conductor, no Forgejo, no external
  secret store" line is now "No orchestrator, no external secret store,
  no sync server."
- **`docs/design-decisions.md`** — stripped the v0.2.0 xyOps-to-LaunchAgent
  migration narrative (which referenced `infra-agent`, `Conductor`,
  `Forgejo`, internal hostnames). The architectural conclusion is
  preserved as the "Why a LaunchAgent for sync, not a LaunchDaemon"
  section, framed forward-looking instead of as a transition story.
  The "Why credential resolution is env-var-then-Keychain (no 1Password)"
  section replaces the "Why drop the 1Password fallback (v0.2.0)" historical
  note. The `umbridge` / `hedwig` / `johntrandall` references in path
  examples are now `<nas>` / `<name>`.
- **`docs/roadmap.md`** — internal planning artifact. Trashed (moved to
  the user trash, not git-deleted; recoverable for the author).
- **`launchd/com.johnrandall.hither.bootstrap.plist`** —
  `ServiceDescription` stripped of:
  - `umbridge`/`hedwig` example hostnames (replaced with generic
    "wiping previously-installed indirect-map entries"),
  - `/etc/sudoers.d/xysat-hither-sync` reference (now correctly references
    `/etc/sudoers.d/hither-write-map` and the `%admin` grant model),
  - the field-report internal URL and ADR-NNN reference.
  Also: `ProgramArguments` no longer hardcodes `umbridge`. The daemon
  now iterates `/etc/hither_*` and re-applies the auto_master line for
  whichever NAS subscriptions exist on disk.
- **`launchd/com.johnrandall.hither.sync.plist`** — `ServiceDescription`
  reference to internal ADR scrubbed. The `EnvironmentVariables` defaults
  for `TARGET_USER` and `NAS_LIST` are now `PLACEHOLDER_USER` and
  `PLACEHOLDER_NAS` (overwritten on first `hither subscribe`). An XML
  comment in the plist documents that these are placeholders.
- **`libexec/hither-sync.sh`** — header comments rewritten to drop the
  "Where this runs: Each Mac's xysat worker runs this locally" framing.
  The current text describes the LaunchAgent + `hither sync` execution
  contexts. Placeholder defaults updated to match the plist
  (`PLACEHOLDER_USER` / `PLACEHOLDER_NAS`).
- **`sbin/hither-write-map`** — header rewritten. The reference to
  `xysat (running as infra-agent)` is now "the user's LaunchAgent (or
  `hither sync`)". The path-traversal vulnerability description is
  generalized to "older auto-smb sync schemes."
- **`scripts/doctor.sh`** — the hardcoded `for host in umbridge` loop
  is replaced with subscription-driven iteration over
  `~/.config/hither/subscriptions/*.toml`, with a fallback to
  whatever indirect maps exist at `/etc/hither_*`. The hardcoded
  `find-internet-password -s umbridge -a johntrandall` check now reads
  the host + user from each subscription's TOML.

What deliberately did NOT change:

- **The LaunchDaemon Label `com.johnrandall.hither.bootstrap` and
  LaunchAgent Label `com.johnrandall.hither.sync`** still carry the
  original author's name as the reverse-DNS prefix. These Labels are
  baked into existing installs (the author's primary Mac has been
  running them since 2026-05-19); renaming would break upgrade paths
  for anyone already running v0.1-v0.3. Both plists now include a
  `Note on the Label` paragraph in `ServiceDescription` explaining why
  the name is historical and that it isn't going to change.
- **The sudoers grant model** — `%admin ALL=(root) NOPASSWD:
  /usr/local/sbin/hither-write-map ^[a-z0-9-]+$`. Generic, regex-bounded,
  no John-specific account names.
- **The Keychain credential model** — unchanged. Keychain is the canonical
  store; the env-var override path is preserved.
- **`bin/hither` CLI surface** — unchanged. Only the
  `bootstrap_user_phase` placeholder comment was tightened.

### Added

- **`Formula/hither.rb`** — Homebrew formula. Installs `bin/hither` to
  the Cellar, libexec scripts to `libexec/`, the bootstrap / launchd /
  sbin / sudoers / scripts / completions trees to `pkgshare`, and bash
  + zsh completions to the Homebrew-standard locations. The `caveats`
  block documents the two-phase bootstrap and the reboot requirement.
  The `sha256` is a placeholder filled at release time against the
  GitHub release tarball.
- **`docs/HOMEBREW.md`** — procedure for setting up the
  `johntrandall/homebrew-hither` tap repo. The formula lives in this
  repo as the source of truth; the tap repo is a mirror.

### Status

The Homebrew tap (`github.com/johntrandall/homebrew-hither`) does NOT
exist yet. v0.4.0 ships the formula in this repo as the canonical
source; the operator publishes the tap as a follow-up. README
documents the tap path as the recommended install method with a note
that the tap is coming.

### Version bump

- `bin/hither` `HITHER_VERSION` → `0.4.0`
- `Formula/hither.rb` `version` → `0.4.0`

## [0.3.1] — 2026-05-20

Repo cleanup — the xyOps coupling that v0.2.0 made dead code is now actually deleted, the sudoers file is renamed to match the wrapper it grants, and the bootstrap installs the sudoers grant automatically (was previously a manual operator step).

### Removed
- `server/register-events.sh` — xyOps event-registration script. Made dead code in v0.2.0; deleted now.
- `server/hither-sync.manifest.json` — xyOps subscriber list. v0.3.0 replaced this model with `~/.config/hither/subscriptions/<nas>.toml`. Deleted.
- `server/sudoers/xysat-hither-sync` — the sudoers file's xysat-association naming. Renamed (see below).
- `server/` directory — now empty, removed.
- `scripts/verify-no-leaks.sh` no longer has `--exclude-dir=server` since the directory is gone. The leak gate now scans every file in the repo.

### Renamed
- `server/sudoers/xysat-hither-sync` → `sudoers/hither-write-map`. Name now matches the wrapper it grants (`/usr/local/sbin/hither-write-map`). Sudoers Runas user changed from `infra-agent` (John-personal service account) to `%admin` (generic; the first-created user on any macOS install is in the admin group).

### Added
- `bin/hither bootstrap` root phase now installs `sudoers/hither-write-map` to `/etc/sudoers.d/hither-write-map` after validating with `visudo -cf`. Previously the operator had to do this manually.
- `bin/hither bootstrap` also removes the legacy `/etc/sudoers.d/xysat-hither-sync` file if present (clean migration from v0.1/v0.2 installs).
- `bin/hither uninstall` removes `/etc/sudoers.d/hither-write-map` (and the legacy file if still present).

### Migration for the SusanBones install

`sudo $(which hither) bootstrap` picks up the new sudoers automatically and removes the legacy file.

## [0.3.0] — 2026-05-20

CLI surface completeness — Hither's per-Mac operator interface, finished. v0.2.0 left the daemons in place but the CLI was still ad-hoc (subscribe-by-hand: edit the plist, `security add-internet-password`, hand-edit auto_master). v0.3.0 ships the full lifecycle as proper subcommands. Subscription state is now a real on-disk artifact at `~/.config/hither/subscriptions/<nas>.toml`, one file per NAS, and every other piece of system state (Keychain entry, `/etc/auto_master` line, LaunchAgent env block, `/etc/hither_<nas>` map) flows from there.

### Added
- `hither subscribe <nas> --user <dsm-user> [--proto http|https] [--schedule-hour H] [--schedule-minute M]` — add a NAS subscription. Prompts for the DSM password (or reads it from piped stdin), stores it via `security add-internet-password -s <nas> -a <user> -r 'smb '`, writes the subscription TOML, applies the `/etc/auto_master` line via `sudo -n` (best-effort; falls back to a hint if sudo cache is empty), re-renders the LaunchAgent's `NAS_LIST` / `TARGET_USER` env block, and fires an initial sync. Validates the NAS name against the same `^[a-z0-9-]+$` regex enforced by `/usr/local/sbin/hither-write-map`.
- `hither unsubscribe <nas> [--purge]` — reverse of subscribe. Best-effort unmounts any current mounts, deletes the subscription file, removes the `/etc/auto_master` line (sudo), removes `/etc/hither_<nas>`, and refreshes the LaunchAgent env. `--purge` also deletes the Keychain entry (documented as irreversible).
- `hither list` — tabular subscription view: NAS, user, proto, schedule, share count (from `/etc/hither_<nas>` line count), last sync age (from file mtime).
- `hither status` — one-screen state snapshot: LaunchDaemon + LaunchAgent loaded state, `/etc/synthetic.conf` form check, `/etc/auto_master` entry count, `/Hither` symlink check, per-subscription summary including stale-mount detection (`timeout 2 stat -f '%t' <mountpoint>` per mounted share).
- `hither unmount <nas> | <nas>/<share> | all` — `umount -f` shares Hither manages. `all` walks every subscription. Best-effort; reports each umount's exit code.
- `hither remount <nas> | all` — `hither unmount` + `sudo automount -cv` to kick autofs's map cache.
- `hither logs [<nas>] [--tail]` — `cat ~/Library/Logs/hither/sync.log` with optional grep-filter to one NAS and optional `tail -F`.
- `hither uninstall [--purge]` — reverse of `bootstrap`, two phases (user + root). Removes LaunchAgent, LaunchDaemon, `/usr/local/sbin/hither-write-map`, `/usr/local/libexec/hither/`, the `/Hither` line from `/etc/synthetic.conf`, all `/Hither/` lines from `/etc/auto_master`, and the `/etc/hither_*` maps. `--purge` also removes `~/.config/hither/` and every per-NAS Keychain entry. Documented that synthetic-root removal only takes effect after reboot.
- `libexec/hither-lib.sh` — shared bash helpers sourced by `bin/hither`. Houses subscription file I/O (`hither_sub_read_field`, `hither_sub_write`, `hither_sub_list_names`, `hither_sub_iter`) and `hither_refresh_launchagent_env` which re-renders the agent plist from the current subscription set and reloads it via `launchctl bootout` + `bootstrap`. Avoids taking a TOML-parser dependency; uses `awk` against the flat `key = "value"` form.

### Changed
- **Subscriber list is no longer hardcoded.** `bin/hither bootstrap` (root phase) now iterates `~/.config/hither/subscriptions/*.toml` instead of a literal `for host in umbridge`. When sudo'd, it reads from `$SUDO_USER`'s home, not root's. First-time installs (no subscriptions yet) skip the auto_master loop and print a hint to run `hither subscribe` next.
- **`hither sync` accepts an optional NAS argument.** Without args: syncs every subscription (TARGET_USER + NAS_LIST + NAS_PROTO derived from the current subscription files). With `<nas>`: syncs that one only. Backwards-compat fallback: if no subscriptions exist, fall through to `hither-sync.sh`'s env-var defaults — keeps mid-migration installs working.
- **`hither bootstrap --user-only` refreshes the LaunchAgent env block from subscriptions.** If any subscriptions exist, the installer pipes the plist through `awk` to substitute `NAS_LIST` and `TARGET_USER` before loading. If none exist, the placeholder values stay in the plist; `hither subscribe` will overwrite them later.
- `bin/hither` `usage()` rewritten to cover all subcommands with one-line descriptions. `bin/hither` source grew from 254 to ~620 lines (most of the growth is comments + the `usage()` heredoc; logic is partitioned into `cmd_<name>` functions).
- Bash + zsh completions updated. Bash completion now dynamically reads `~/.config/hither/subscriptions/*.toml` to suggest NAS names for `unmount` / `remount` / `sync`.
- `VERSION` → `0.3.0`.

### Notes
- `server/` directory NOT removed — Phase 4 cleanup is still pending until the xyOps event burn-in concludes. The `verify-no-leaks` `--exclude-dir=server` carve-out stays.
- `bootstrap` retains its name (not renamed to `install`) — minimizing churn for v0.3.0; the rename is deferred to v0.4.0 per the roadmap.
- Multi-user-per-Mac is not supported. If subscriptions specify different `user` values, `refresh_launchagent_env` warns and uses the first. Multi-user is in the post-v1.0 "Out-of-scope" list.

### Test cycle (manual, on the dev host)
```
hither version                                  → "hither 0.3.0"
hither subscribe BAD-NAME --user u <<< pw       → exits non-zero ("invalid — must match …")
hither subscribe foo --user u --schedule-hour 25 → exits non-zero ("must be 0-23")
hither subscribe testnas --user testuser <<< pw → writes ~/.config/hither/subscriptions/testnas.toml, stores Keychain
hither list                                     → shows testnas | testuser | http | 04:23 | - | never
hither unsubscribe testnas --purge              → deletes file + Keychain entry; subsequent `list` is empty
hither status                                   → runs on a 0-subscription Mac without crashing
hither verify-no-leaks                          → exits 0
bash -n bin/hither libexec/hither-lib.sh        → clean
```

## [0.2.0] — 2026-05-20

Drop the xyOps coupling. Hither is now a self-contained per-Mac tool: the daily sync runs as a LaunchAgent in user GUI context, reads DSM credentials from macOS Keychain, and has zero external orchestration dependencies. This is the architecture target distribution work needs (per `docs/roadmap.md`'s "design north star").

The xyOps event `empd62jad27xpjy3` remains running in production during burn-in (defense in depth) — the LaunchAgent's writes happen in parallel and overwrite the same `/etc/hither_umbridge` file. After a week of clean LaunchAgent firings, the xyOps event will be decommissioned in a follow-up release.

### Added
- `launchd/com.johnrandall.hither.sync.plist` — LaunchAgent template, fires daily at 04:23 local time. Includes a multi-paragraph `ServiceDescription` per the user-global `launchd-service-description` skill. `StandardOutPath` / `StandardErrorPath` use a `__HOME__` install-time substitution token (launchd does not expand env vars in plist paths).
- `bin/hither sync` subcommand — manual fire of the daily sync from a user shell. Refuses to run as root (Keychain access requires user GUI session). Equivalent to `launchctl kickstart gui/$(id -u)/com.johnrandall.hither.sync`.
- `bin/hither bootstrap --user-only` flag — installs the LaunchAgent to `~/Library/LaunchAgents/` and bootstraps it into `gui/$(id -u)`. Refuses to run as root (sudo would land the plist in root's home).
- `scripts/doctor.sh` now checks both the LaunchDaemon (revert defender) and the LaunchAgent (sync) are loaded, and that the installed sync script exists at `/usr/local/libexec/hither/hither-sync.sh`.

### Changed
- **Architecture: server-side script becomes per-Mac script.** `server/hither-sync.sh` → `libexec/hither-sync.sh`. The script body itself stays largely the same (DSM API call, render map, write via wrapper) — what changes is where it runs. Previously: fetched by xysat from Forgejo at fire time and exec'd from `/tmp/`. Now: installed to `/usr/local/libexec/hither/hither-sync.sh` by `hither bootstrap` and exec'd by the LaunchAgent (and by `hither sync`).
- **Credential model: 1Password fallback dropped; Keychain becomes primary.** `dsm_login` now resolves DSM passwords via `${NAS_UPPER}_DSM_PASSWORD` env-var override → `security find-internet-password -s <nas> -a <user> -w` (Keychain). The `op item get` path is removed entirely. Users who keep DSM passwords in 1Password can still inject via env-var override (e.g. `UMBRIDGE_DSM_PASSWORD=$(op read ...) hither sync`). The `OP_VAULT` env var is removed.
- **`bin/hither bootstrap` split into root and user phases.** The root phase (file installs under `/etc/`, `/usr/local/`, `/Library/LaunchDaemons/`) runs via `sudo`. The user phase (LaunchAgent install under `~/Library/LaunchAgents/`, bootstrap into `gui/$(id -u)`) runs as the consuming user, no sudo. The combined-default-behavior (one `sudo hither bootstrap` invocation does both) is intentionally NOT supported — sudo's EUID would land the LaunchAgent in root's home. Operator runs the two phases as two commands.
- **`bin/hither bootstrap` now installs `hither-sync.sh` to `/usr/local/libexec/hither/`.** Same pattern as the v0.1.1 split for the bootstrap scripts: keeps daemon-invoked code out of user-home repos (which may be mode-700, relocated, or deleted).
- Sync log path: `~/Library/Logs/hither-sync.log` → `~/Library/Logs/hither/sync.log` (sub-directory for clean per-tool grouping; the LaunchAgent writes `sync.stderr.log` alongside).
- `VERSION` → `0.2.0`.

### Removed (from runtime; source preserved for one release)
- `op` CLI dependency. The check loop in `hither-sync.sh` now requires `security` instead.
- `OP_VAULT` env var.
- xyOps-specific header comments in the sync script. The script no longer claims to be "the server side."

### Not removed (yet — Phase 4 cleanup)
- `server/hither-sync.manifest.json`
- `server/register-events.sh`
- `server/sudoers/xysat-hither-sync`

These remain in the repo through the burn-in period. The xyOps event `empd62jad27xpjy3` is still firing in production daily; keeping these source files means we can re-register the event if v0.2 fails. After a clean burn-in (~ one week), a separate commit deletes `server/` entirely and drops the `verify-no-leaks.sh` `--exclude-dir=server` carve-out.

### Migration
Existing v0.1.1 installs (SusanBones) upgrade via:
```
sudo $(which hither) bootstrap          # root phase: re-install libexec, reload LaunchDaemon
hither bootstrap --user-only            # user phase: install + load LaunchAgent
# Prime Keychain (one-time, only if Finder Cmd-K hasn't already done it):
security add-internet-password -s umbridge -a johntrandall -r 'smb ' -w
```

## [0.1.1] — 2026-05-19

Hardening pass after a 5-agent verification review of the live SusanBones deployment. System was healthy in production; this release lands the P0 fix and the P1 bundle so the daemon can defend the system without operator intervention if macOS strips state.

### Fixed
- **P0** `bootstrap/add-synthetic-root.sh` now writes the two-column symlink form (`Hither<TAB>System/Volumes/Data/Hither`) — the prior single-column directory form created a stub at `/Hither` that cannot host autofs mounts on a sealed system volume. Production already has the symlink form because the operator hand-edited it post-install; this change guarantees the LaunchDaemon's revert defender restores the correct form if macOS ever wipes `/etc/synthetic.conf`. Idempotency check inverted: symlink form is now `[skip]` (correct), legacy directory form is `[warn]`.
- `bootstrap/apply-auto-master.sh` lock acquire now checks for a stale lock dir older than 5 minutes and breaks it. Recovers from a SIGKILL'd prior run without manual intervention.
- `sbin/hither-write-map` now writes a `/etc/hither_${host}.needs-reload` marker if `automount -cv` fails after a successful map write. `hither-sync.sh` checks the marker before its diff comparison and re-invokes the wrapper unconditionally if present, so a transient autofs failure no longer leaves stale state until reboot.
- `server/register-events.sh` wrapper template now sets `trap 'rm -f "$TMP"' EXIT` so the curl'd script tempfile is cleaned on failure paths.
- `scripts/verify-no-leaks.sh` no longer fail-opens when the patterns file is missing. Default is fail-closed (exit 2) with a setup hint; CI / sandboxed environments opt out via `HITHER_LEAK_PATTERNS_OPTIONAL=1`.

### Changed
- LaunchDaemon plist no longer references a user-home repo path. `bin/hither bootstrap` now installs the bootstrap scripts to `/usr/local/libexec/hither/{add-synthetic-root,apply-auto-master}.sh` (root-owned, mode 0755). The plist's `ProgramArguments` invokes those system paths. Eliminates the mode-700 user-home dependency and matches the wrapper's `/usr/local/sbin/` install pattern.
- `install-launchdaemon.sh` detects plist content changes and runs `bootout` + `bootstrap` to reload, instead of silently no-op'ing when a stale plist is already loaded.
- `docs/architecture.md` rewritten to reflect the actual deployed model: xysat satellites on each Mac pull `hither-sync.sh` from Forgejo at a pinned SHA and run it locally; the Conductor on Umbridge schedules but does not execute. Prior doc described an SSH-from-Synology model that has never been deployed.
- README's bootstrap steps reordered to match `bin/hither` code order (synthetic.conf → auto_master → wrapper → LaunchDaemon).
- `server/register-events.sh` stale comment/log strings referencing `admin-technical` updated to `dev/hither`. The xyOps secret name `forgejo-ro-admin-technical` is retained as a real resource name; clarifying comment added.

### Documented
- `server/sudoers/xysat-hither-sync` now includes a paragraph explaining that the `^[a-z0-9-]+$` argument form is a regex (sudo ≥ 1.9.10 feature) — two independent verifiers misread it as a fnmatch pattern. Empirically working on macOS Sequoia (sudo 1.9.13p2).

## [0.1.0] — 2026-05-19

Initial private import of Hither (v1).

### Added
- CLI: `hither bootstrap`, `hither doctor`, `hither verify-no-leaks`, `hither version`
- Wrapper: `/usr/local/sbin/hither-write-map` — root-owned, arg-validated, atomic-write, runs `automount -cv` internally. Closes path-traversal vulnerability of prior `tee /etc/auto_smb_*` sudoers wildcard.
- LaunchDaemon: `com.johnrandall.hither.bootstrap` — re-applies `/etc/auto_master` + `/etc/synthetic.conf` state at boot and on WatchPaths trigger. Defends against macOS update reverts (motivating incident: macOS 15.7.7 on 2026-05-15 wiped `/Network/umbridge` and `/Network/hedwig` entries).
- Synthetic root `/Hither/` via `/etc/synthetic.conf`; materialized without reboot via `apfs.util -t`.
- Server side: `server/hither-sync.sh` (renamed from `auto-smb-sync.sh` in admin-technical), runs under xyOps on Umbridge; enumerates DSM shares and pushes per-Mac maps via the wrapper.
- Documentation: README, docs/architecture.md, docs/design-decisions.md, docs/glossary.md.
- Install: `lash install` (dev-clone path).

### Scope (v1)
- Single subscriber: SusanBones.
- Single source: Umbridge (Synology DSM).
- PRIVATE repo only.

### Deferred to v2
- Hedwig + other static-peer Macs (need different "static-curated map" mode).
- Other subscriber Macs.
- Public release + sanitization.
- Homebrew tap formula.
- `hither subscribe` / `hither add-peer` CLI subcommands.

### Forked from
- `admin-technical/setup/synology/xyops/jobs/auto-smb-sync*` (fresh-copy import; no admin-technical git history preserved).
- `admin-technical/setup/macos/autofs-umbridge/setup-autofs-umbridge.sh` (logic only; runtime data heredoc deliberately not copied).
