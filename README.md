# Hither

**Bring it here.** A lazy mounter for personal Mac SMB fleets.

Hither makes the shares on your Synology (or other DSM-speaking NAS) appear at predictable, stable paths — `/Hither/<nas>/<share>` — on every Mac you own. Shares mount on first access, unmount when idle, and survive macOS updates that would normally wipe your autofs configuration.

```
$ ls /Hither/myserver/
Documents  Media  Photos  Projects

$ cat /Hither/myserver/Documents/notes.md
…
```

No GUI to open, no `Connect to Server…` dialog, no broken Finder sidebar shortcuts after every OS update. The shares are just there.

## Why this exists

If you've tried to set up autofs on macOS for a personal NAS, you've probably hit some combination of:

- **macOS system updates wipe `/etc/auto_master`.** The next morning, every indirect map you carefully configured is gone, and `cd /Network/myserver` silently fails until you notice.
- **The traditional `sudoers` workaround is a security hole.** Grants like `<user> ALL=(root) NOPASSWD: /usr/bin/tee /etc/auto_smb_*` look fine, but the `*` glob matches `/` — meaning `sudo tee /etc/auto_smb_../passwd` is a legal path-traversal escape to arbitrary root file write.
- **`/Network` is confusing.** Finder's "Network" sidebar item is a Bonjour browser; the macOS path `/Network` is autofs's traditional mount root. Two unrelated things, same name, both visible to users.
- **Credentials want to live in two places.** macOS has Keychain. You add the share once via Finder Cmd-K, the password lives in Keychain, and that's the canonical source of truth — except every script-based mounter you find wants you to put the password somewhere else.

Hither addresses all four:

- A LaunchDaemon **watches `/etc/auto_master` and `/etc/synthetic.conf`** and re-applies its lines whenever macOS reverts them.
- A root-owned **wrapper script with an `^[a-z0-9-]+$` host-name whitelist** replaces the path-traversable sudoers wildcard.
- Mounts go under **`/Hither/`** — sidesteps the Finder/autofs naming collision, matches macOS's CamelCase root convention (`/Applications`, `/Library`, `/Volumes`).
- Credentials come from the **macOS Keychain** — the same entry Finder Cmd-K populates for SMB mounts. No separate secret store.

## Install

> **Note:** the Homebrew tap is not yet published. Install from source today (below); the `brew` form will land at v1.0.

For now, install from source:

```bash
git clone https://github.com/johntrandall/hither.git ~/hither
cd ~/hither
sudo bin/hither bootstrap         # root phase: /etc/, /usr/local/, LaunchDaemon
bin/hither bootstrap --user-only  # user phase: ~/Library/LaunchAgents
```

The future Homebrew path will be:

```bash
brew install johntrandall/hither/hither   # v1.0+ — not yet live
sudo $(brew --prefix)/bin/hither bootstrap
hither bootstrap --user-only
```

The `Formula/hither.rb` in this repo is the formula that will ship in the tap.

After bootstrap, add your first NAS:

```bash
hither subscribe <nas> --user <dsm-user>
```

You'll be prompted for the DSM password (input hidden). Hither stores it in the macOS Keychain — the same entry Finder Cmd-K writes — and fires an initial sync. `/Hither` is materialized in the same bootstrap pass via `apfs.util -t` — no reboot needed in normal cases. If `ls /Hither` after install shows "No such file or directory", reboot once as a fallback and re-check; `hither doctor` will also flag the missing synthetic root.

```bash
ls /Hither/<nas>/
```

…and every share you can read on the NAS is there.

### Manual install

```bash
git clone https://github.com/johntrandall/hither.git ~/dev/hither
cd ~/dev/hither
# Symlink bin/hither into your PATH however you prefer (e.g., ln -s "$PWD/bin/hither" ~/.local/bin/hither).
sudo $(which hither) bootstrap
hither bootstrap --user-only
hither subscribe <nas> --user <dsm-user>
```

## CLI

```
hither bootstrap [--reapply-only|--user-only|--root-only]
                                          Install / re-apply Hither system state
hither subscribe <nas> --user <dsm-user> [--notify|--no-notify|--notify=true|--notify=false]
                                          Add a NAS, store password in Keychain
hither unsubscribe <nas> [--purge]        Remove a NAS subscription
hither list                               Show subscribed NASes + last-sync age
hither sync [<nas>] [--notify|--no-notify|--notify=true|--notify=false]
                                          Manual fire of the daily sync
hither status                             Daemon + config + mount state
hither unmount <nas> | <nas>/<share> | all   Force-unmount with umount -f
hither remount <nas> | all                Unmount + automount -cv
hither logs [<nas>] [--tail]              Show / follow the sync log
hither doctor                             Mount probes, Keychain, daemons, TM
hither verify-no-leaks                    Pre-commit privacy gate
hither uninstall [--purge]                Reverse of bootstrap
hither version                            Print version
```

Common recipes:

```bash
# Subscribe to a second NAS (HTTPS, custom schedule)
hither subscribe othernas --user me --proto https --schedule-hour 5

# Tabular health/state view
hither status

# Force a sync now, for one NAS or all subscriptions
hither sync                     # all subs
hither sync <nas>               # one sub

# Force-unmount stuck shares
hither unmount <nas>/Media      # one share
hither unmount <nas>            # every mounted share under /Hither/<nas>/
hither unmount all              # every Hither-managed mount

# Override the password out-of-band (e.g. from a password manager)
NAS_DSM_PASSWORD=$(op read 'op://Personal/<nas>/password') hither sync
# (Env var is ${NAS_UPPER}_DSM_PASSWORD where NAS_UPPER is your nas
# subscription name, uppercased; dashes → underscores.)
```

## How it works

Two daemons on each Mac, with non-overlapping responsibilities:

| Daemon | Type | Context | Role | Network? |
|---|---|---|---|---|
| `com.johnrandall.hither.bootstrap` | LaunchDaemon | root | Re-apply `/etc/synthetic.conf` + `/etc/auto_master` on revert; RunAtLoad + WatchPaths | never — runs before networking is up |
| `com.johnrandall.hither.sync` | LaunchAgent | user GUI | Daily DSM API call → render map → write via `hither-write-map` | yes |

The LaunchAgent runs in user GUI context (required for Keychain access). It calls the DSM Web API **as the target user**, which means the server-side ACL filter returns exactly the shares that user can read. The script renders an autofs indirect-map body and pipes it through a root-owned wrapper script that atomically writes `/etc/hither_<nas>` and runs `automount -cv`.

When the share-set changes between syncs — the NAS admin adds a share you can now read, or revokes one you used to see — Hither surfaces that as a macOS user notification ("Hither — *nas*: + Photos / − OldShare"). New subscriptions opt into this by default; turn it off per-subscription with `hither subscribe <nas> --user <u> --notify=false`, or for a single manual sync with `hither sync --no-notify`.

**Notification opt-in semantics, in detail.** New subscriptions created on v0.5.0+ default to `notify_on_changes = true`. Subscriptions created under v0.4.x predate the field — the absent field reads as `false` via `hither_sub_read_notify`, so upgraded installs stay silent by default. The runtime gate is a *single global* `HITHER_NOTIFY` env var on the LaunchAgent, OR-aggregated across all subscriptions: as soon as **any** subscription has `notify_on_changes = true`, the LaunchAgent fires with `HITHER_NOTIFY=1` and ALL subscriptions on that Mac route through the notification code path. So adding one new v0.5.0+ subscription with the default-true notify silently enables notifications for every existing sub on the same Mac — including v0.4.x-upgraded subs that were previously silent. To keep an upgraded sub silent, set its TOML `notify_on_changes = false` explicitly, or use `hither subscribe <nas> --notify=false` when adding new subs. Per-NAS notify gating is on the post-v1.0 roadmap; the TOML field is per-subscription (forward-compat) but the runtime gate is global.

The LaunchDaemon never touches the network and never `stat`s anything under `/Hither/`. Its only job is to keep `/etc/synthetic.conf` and `/etc/auto_master` from drifting.

See **[docs/architecture.md](docs/architecture.md)** for the full data flow and **[docs/design-decisions.md](docs/design-decisions.md)** for *why* it's built this way.

> **About the LaunchDaemon labels.** Both `Label`s start with `com.johnrandall.` — the original author's reverse-DNS prefix. These labels are baked into existing installs and we don't rename them in the v0.x series to avoid breaking upgrade paths. They aren't visible to typical users; operators inspecting `launchctl list` will see them.

## Requirements

- **macOS 15.7+ (Sequoia)** — symlink-form `synthetic.conf` and the `apfs.util -t` materialization path are tested on 15.7.x. Earlier releases are likely to work but untested.
- **DSM 7.3+** on the NAS (Synology). Hither uses `SYNO.API.Auth` and `SYNO.FileStation.List`, which have been stable across DSM 7.x.
- **`sudo >= 1.9.10`** (April 2022) — the sudoers grant in `sudoers/hither-write-map` uses sudo's regex-argument syntax (`^[a-z0-9-]+$`), introduced in 1.9.10. macOS Sequoia ships 1.9.13p2; Ventura also OK.
- **`curl`, `jq`** — both ship with macOS (`jq` arrived in 15.0).
- **An admin-group user** on each Mac. The sudoers grant is to `%admin`; the first user created on any macOS install is in `admin`, so this is usually the family member's normal account.

Hither itself has no Python, no Node, no Go runtime. It's a few hundred lines of bash + zsh + two launchd plists.

## Status

**v0.5.0 — share-set change notifications.** Building on the v0.4.0 public-release polish (the first release intended for an audience beyond the author), v0.5 surfaces share-set drift as a native macOS notification: when a NAS-side admin grants or revokes your access to a share, you find out at the next sync rather than via a stale `cd /Hither/<nas>/<share>` failure. The two-daemon architecture has been stable since v0.2.0, the CLI surface since v0.3.0, and the privacy/leak gate since v0.1.

Under active development on the author's primary Mac. The same DSM-API-to-autofs-map flow has been running daily in an earlier form (a centrally-scheduled job) since early May 2026; v0.2.0+ is a self-contained refactor of that flow. **v1.0 will be cut after a clean 30-day burn-in of the LaunchAgent form.** Until then, expect minor changes — the on-disk subscription format and CLI surface are not expected to change incompatibly, but no promises until v1.0.

## Contributing

Issues and PRs welcome. For substantive changes, please open an issue first so we can talk about scope — Hither's design north star is *self-contained per-Mac tool*, and features that pull state out of the Mac (a sync server, a fleet console, a shared config repo) are deliberately out of scope.

If you want a code-tour without reading every file, start with:

1. [`docs/architecture.md`](docs/architecture.md) — what the two daemons do, and the data flow.
2. [`docs/design-decisions.md`](docs/design-decisions.md) — why it's built that way (alternatives considered and rejected).
3. [`bin/hither`](bin/hither) — the CLI is the visible surface.
4. [`libexec/hither-sync.sh`](libexec/hither-sync.sh) — the load-bearing sync logic.

## License

[MIT](LICENSE). Copyright (c) 2026 John Randall.
