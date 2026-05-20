# Hither roadmap — v0.2.0 → v1.0

This file captures the publication-readiness work being executed in the
2026-05-19/20 session. It is a working planning artifact, not a public
roadmap.

## Design north star

**Hither must be a self-contained per-Mac tool.** Distribution means
strangers can `brew install johntrandall/hither/hither`, run two
commands, and have working lazy-mounted SMB shares. Anything that
requires a separate Conductor, fleet-wide infrastructure, or per-operator
ceremony is wrong for a packaged tool.

Personal-infra concerns (cross-Mac xyOps visibility, ticket routing,
1Password vault structure) are John-specific. They do not belong in
Hither's core. Hither stays generic; John runs Hither alongside
whatever fleet management he wants.

## Architecture target (v0.2.0+)

Two daemons, clean separation, no external orchestration:

| Daemon | Context | Role | Network? |
|---|---|---|---|
| `com.hither.defender` | LaunchDaemon (root) | Re-apply `/etc/synthetic.conf` + `/etc/auto_master` on revert; RunAtLoad + WatchPaths | **never** — runs before Tailscale/Wi-Fi |
| `com.hither.sync` | LaunchAgent (user) | Daily DSM API call → render map → write via `hither-write-map`; on-demand via `hither sync` | yes |

The LaunchAgent runs in user GUI context, which has Keychain access. SMB
credentials live in macOS Keychain (`security add-internet-password`).
No 1Password dependency.

## v0.2.0 — drop xyOps, native LaunchAgent

**Removed:**
- `server/register-events.sh` — xyOps event registration (deleted)
- `server/hither-sync.manifest.json` — xyOps subscriber list (deleted; replaced by per-user subscription files)
- `server/sudoers/xysat-hither-sync` — renamed to `sudoers/hither-write-map` (drops "xysat" association)

**Relocated:**
- `server/hither-sync.sh` → `libexec/hither-sync.sh` (the share-iteration logic stays, but it's no longer "server-side"; installed to `/usr/local/libexec/hither/hither-sync.sh`)

**Added:**
- `launchd/com.hither.sync.plist` — daily LaunchAgent template, installed to `~/Library/LaunchAgents/`
- Credential lookup via macOS Keychain (`security find-internet-password -s <nas> -a <user>`)
- `bin/hither sync` subcommand (manual fire)

**Modified:**
- `bin/hither bootstrap` — installs LaunchAgent in addition to LaunchDaemon
- `verify-no-leaks.sh` — drops `--exclude-dir=server` (server/ is gone)

**xyOps event on Umbridge:** `empd62jad27xpjy3` stays running during burn-in (defense in depth). Operator decommissions manually after v0.2 LaunchAgent has run cleanly for a week.

## v0.3.0 — CLI completeness

New subcommands:

```
hither subscribe <nas> --user <dsm-user>   # add NAS, prompts for password, stores in Keychain, triggers initial sync
hither unsubscribe <nas>                   # remove subscription, unmount, clean up map file
hither list                                # show subscribed NASes + last-sync + share counts

hither sync [<nas>]                        # manual trigger; defaults to all
hither status                              # daemons + config + mount state + stale-mount detection

hither unmount <nas> | <nas>/<share> | all # umount -f shares Hither manages
hither remount <nas> | all                 # unmount + automount -cv

hither logs [<nas>] [--tail]               # show recent sync log
```

Subscription state lives at `~/.config/hither/subscriptions/<nas>.toml`:

```toml
[subscription]
name = "umbridge"
user = "johntrandall"
nas_proto = "http"  # or "https"
schedule_hour = 4
schedule_minute = 23
```

`bin/hither` becomes a router; per-subcommand implementations live in
`libexec/hither/cmd/<name>.sh`.

## v0.4.0 — public-ready polish

- README rewrite for public audience (no internal hostnames, no PII)
- `publish-pre-flight-audit` skill applied (privacy gate)
- Homebrew tap: `johntrandall/hither` — `brew install johntrandall/hither/hither`
- LICENSE confirmed (MIT, already in repo)
- CHANGELOG polish
- Drop dev-docs/roadmap.md (or move to .git-archived/)

## v1.0 — public release

- Public GitHub repo (currently private)
- Announce / Show HN / Reddit r/macsysadmin
- `outreach-show-hn` skill invoked

## Out-of-scope (deliberately deferred past v1.0)

- Multi-NAS support beyond DSM (Hedwig, generic SMB peer lists)
- Network-change event handler (auto-unmount on SSID change)
- `hither subscribe --interactive` GUI prompt via osascript
- macOS notification on share added/removed
- Configurable schedule cadence (just daily for now)

## Test strategy

Each phase commit must pass:

1. **Syntax** — `bash -n`, `zsh -n`, `plutil -lint`, `visudo -cf`
2. **Static analysis** — `shellcheck` where applicable
3. **`hither doctor` exit 0** on a freshly bootstrapped state
4. **`hither status` accurate** — daemons loaded, config matches, mounts probed
5. **Real install on SusanBones** — `hither install` + `hither subscribe umbridge` + `hither sync` + `hither unmount umbridge` + `hither remount umbridge` complete cycle

The xyOps event `empd62jad27xpjy3` is the canary. As long as it keeps
firing daily and writing `/etc/hither_umbridge` successfully, the
LaunchAgent's parallel writes can be verified by comparing file mtimes
and content.

## Decommissioning the xyOps event

Operator-only, post-burn-in:

1. Confirm LaunchAgent has fired N daily cycles successfully (`hither logs`)
2. Confirm last-N maps match between LaunchAgent and xyOps writes
3. In xyOps UI: disable the `hither-sync-susanbones` event
4. In xyOps UI: remove the `forgejo-ro-admin-technical` secret's
   association with the event (or delete the event)
5. Local cleanup: nothing — LaunchAgent already owns the file
6. `hither doctor` should still pass

## Open architectural questions (post-v1.0)

- Should `hither` support adding shares to Time Machine exclude list explicitly, or rely on autofs's auto-exclude?
- Should `hither subscribe` validate DSM credentials immediately, or accept and let next sync surface auth failure?
- Should `hither status` shell out to `mount_smbfs -d` to detect stale state, or use a faster reachability probe (TCP 445 connect)?
- Network-change handler design: poll vs subscribe to `kSCDynamicStoreKey`?
