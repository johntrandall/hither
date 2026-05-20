# Hither

**Bring it here. A lazy mounter for personal Mac fleets.**

Hither manages autofs maps so that remote SMB shares appear at predictable, stable paths under `/Hither/{host}/{share}` on every Mac in the fleet, with a LaunchDaemon that defends the system configuration against macOS update reverts.

## What this is

Apple's autofs is great when it works and miserable when it doesn't. macOS system updates routinely wipe `/etc/auto_master`, which silently breaks every indirect map on the machine until somebody notices that `cd /Network/foo` no longer triggers a mount. The historical workaround — a `sudoers` grant for `tee /etc/auto_smb_*` — turned out to be path-traversable (the `*` wildcard in a sudo argument matches `/`), making the convenience a security hole. And the `/Network` filesystem path conceptually collides with Finder's "Network" sidebar item, which is actually a Bonjour browser — confusing users who don't realize they're looking at two different things wearing the same name.

Hither addresses all three problems. It mounts under `/Hither/` instead of `/Network/`, sidestepping the Finder naming clash and matching macOS's CamelCase root convention (`/Applications`, `/Library`, `/Volumes`). It uses a root-owned wrapper script with a strict `^[a-z0-9-]+$` host-name whitelist instead of a sudoers wildcard, closing the path-traversal hole. And it ships a LaunchDaemon that watches `/etc/auto_master` and `/etc/synthetic.conf`, re-applying Hither's lines whenever an OS update reverts them.

There is no Hither server — Hither is a per-Mac tool. A LaunchAgent on each Mac fires daily (04:23 local), enumerates the user's SMB-readable shares via the DSM Web API, renders an autofs indirect-map body, and writes it through a root-owned wrapper. The DSM password is read from the macOS Keychain — the same entry Finder uses for SMB mounts — so there is no separate credential store, no external secret manager, no orchestrator. On the client side, autofs handles everything else: shares mount on access, unmount on idle, and the user never sees the wiring.

## Architecture

```mermaid
flowchart LR
    DSM[DSM Web API on NAS]

    subgraph Mac["Each Mac"]
        LA["LaunchAgent: com.johnrandall.hither.sync<br/>(user GUI context, daily 04:23)"]
        SH["/usr/local/libexec/hither/hither-sync.sh"]
        KC[(macOS Keychain)]
        WRAP["/usr/local/sbin/hither-write-map (root)"]
        ETC["/etc/hither_umbridge"]
        AM["/etc/auto_master"]
        SC["/etc/synthetic.conf"]
        LD["LaunchDaemon: com.johnrandall.hither.bootstrap<br/>(root context, RunAtLoad + WatchPaths)"]
        AUTOFS[automountd]
        USER[User: cd /Hither/umbridge/share]

        LA --> SH
        SH --> KC
        SH --> WRAP
        WRAP --> ETC
        LD --> AM
        LD --> SC
        ETC --> AUTOFS
        AM --> AUTOFS
        SC --> AUTOFS
        USER --> AUTOFS
    end

    SH -- "list_share as TARGET_USER" --> DSM
```

Two daemons, clean separation, no external orchestration:

| Daemon | Context | Role | Network? |
|---|---|---|---|
| `com.johnrandall.hither.bootstrap` | LaunchDaemon (root) | Re-apply `/etc/synthetic.conf` + `/etc/auto_master` on revert | never — runs before Tailscale/Wi-Fi |
| `com.johnrandall.hither.sync` | LaunchAgent (user) | Daily DSM API call → render map → write via `hither-write-map` | yes |

The LaunchAgent runs in user GUI context, which has Keychain access. The DSM password lives in the macOS Keychain (`security add-internet-password -s <nas> -a <user>`). No 1Password dependency, no xyOps dependency, no external orchestrator.

## Install

Hither is private through v0.4 — no Homebrew tap yet. Install from a local clone:

```bash
git clone <forgejo-umbridge:dev/hither.git> ~/dev/hither
cd ~/dev/hither
lash install

# Root phase — installs to /etc, /usr/local, /Library/LaunchDaemons
sudo "$(which hither)" bootstrap

# User phase — installs ~/Library/LaunchAgents/com.johnrandall.hither.sync.plist
hither bootstrap --user-only

# Add your first NAS subscription. Prompts for the DSM password and stores
# it in macOS Keychain (the same entry Finder Cmd-K populates for SMB).
hither subscribe umbridge --user johntrandall
```

That's it — `subscribe` writes `~/.config/hither/subscriptions/umbridge.toml`, writes the Keychain entry, applies the `/etc/auto_master` line via `sudo`, refreshes the LaunchAgent's env block so the new NAS appears in `NAS_LIST`, and fires an initial sync. Subsequent days fire automatically at 04:23 local.

The bootstrap root phase performs:

1. Adds the `Hither` synthetic-root symlink entry to `/etc/synthetic.conf` and materializes `/Hither` (via `apfs.util -t`).
2. For each existing subscription, applies the `/etc/auto_master` entry. (First-time installs have none — the loop is a no-op and prints a hint to run `hither subscribe`.)
3. Installs the root-owned wrapper `sbin/hither-write-map` to `/usr/local/sbin/hither-write-map`.
4. Installs the bootstrap scripts and `hither-sync.sh` to `/usr/local/libexec/hither/`.
5. Installs and loads the LaunchDaemon at `/Library/LaunchDaemons/com.johnrandall.hither.bootstrap.plist`.

The user phase installs `~/Library/LaunchAgents/com.johnrandall.hither.sync.plist` (with `__HOME__` substituted at install time) and bootstraps it into the user's `gui/<uid>` launchd domain.

`bootstrap --reapply-only` (root phase only) skips steps 3-5. It is what the boot-time LaunchDaemon runs at WatchPaths trigger — file repair only.

## Recipes

```bash
# Subscribe to a second NAS (HTTPS, custom schedule)
hither subscribe hedwig --user johntrandall --proto https --schedule-hour 5

# List subscriptions and their last-sync age
hither list

# Tabular health/state view (daemons, files, per-sub mounts, stale detection)
hither status

# Fire the daily sync now, for one NAS or all subscriptions
hither sync                # all subs
hither sync umbridge       # one sub

# Look at the sync log
hither logs                # all entries
hither logs umbridge       # filter to one NAS
hither logs --tail         # follow

# Force-unmount stuck shares
hither unmount umbridge/Media     # one share
hither unmount umbridge           # every mounted share under /Hither/umbridge/
hither unmount all                # every Hither-managed mount

# Unmount + reload autofs
hither remount umbridge

# Remove a NAS subscription (keeps the Keychain entry — re-subscribe is easy)
hither unsubscribe umbridge

# Same, but also wipe the Keychain entry (hard to undo)
hither unsubscribe umbridge --purge

# Reverse the entire install (user phase, then root phase)
hither uninstall
sudo "$(which hither)" uninstall
# --purge also removes ~/.config/hither/ and every Keychain entry
hither uninstall --purge
sudo "$(which hither)" uninstall --purge
```

### Manual sync with an out-of-band password

`hither sync` refuses to run as root (Keychain access requires the user GUI session). To override the password via env var, e.g. from a password manager:

```bash
UMBRIDGE_DSM_PASSWORD=$(op read 'op://<vault>/<item>/password') hither sync
```

## Verify

```bash
hither doctor              # mount probes, Keychain, daemons, TM exclusion
hither status              # state snapshot (no probes)
hither verify-no-leaks     # pre-commit privacy gate
```

`doctor` reports the state of the three pieces of system configuration (synthetic root, auto_master entries, hither_* map files), probes a sample mount, and confirms both daemons are loaded. `verify-no-leaks` checks that no live share-path or PII data has been committed back into the repo.

## Sub-projects

| Document | Purpose |
|---|---|
| [docs/architecture.md](docs/architecture.md) | Detailed architecture: both daemons, data flow |
| [docs/design-decisions.md](docs/design-decisions.md) | Why this design — the alternatives considered and rejected |
| [docs/glossary.md](docs/glossary.md) | Terms (autofs, lash, etc.) for non-John readers |
| [docs/roadmap.md](docs/roadmap.md) | Internal planning: v0.2 → v1.0 distribution-readiness work |

The architectural rationale for adopting Hither across the fleet — and superseding the prior `auto_smb_*` sudoers scheme — lives in `admin-technical/ADRs/ADR-NNN-Hither-Lazy-Mounter.md` (TBD).

## File layout

```
hither/
├── README.md                    # this file
├── docs/
│   ├── architecture.md          # detailed architecture
│   ├── design-decisions.md      # rationale
│   ├── glossary.md              # terms for non-John readers
│   └── roadmap.md               # internal planning (v0.2 → v1.0)
├── bin/
│   └── hither                   # CLI (bootstrap, subscribe, list, sync, status, …)
├── sbin/
│   └── hither-write-map         # root-owned wrapper, installed at /usr/local/sbin/
├── libexec/
│   ├── hither-sync.sh           # daily share enumeration; installed at /usr/local/libexec/hither/
│   └── hither-lib.sh            # shared bash helpers sourced by bin/hither (subscription I/O, LaunchAgent refresh)
├── bootstrap/
│   ├── add-synthetic-root.sh    # installs to /usr/local/libexec/hither/; appends "Hither<TAB>System/Volumes/Data/Hither" to /etc/synthetic.conf
│   ├── apply-auto-master.sh     # installs to /usr/local/libexec/hither/; appends /Hither/{host} lines to /etc/auto_master
│   └── install-launchdaemon.sh  # installs the plist to /Library/LaunchDaemons/
├── launchd/
│   ├── com.johnrandall.hither.bootstrap.plist   # LaunchDaemon — revert defender
│   └── com.johnrandall.hither.sync.plist        # LaunchAgent — daily sync (template, __HOME__ substituted at install)
├── server/                      # vestigial — xyOps registration (deleted in Phase 4, post burn-in)
│   ├── hither-sync.manifest.json
│   ├── register-events.sh
│   └── sudoers/xysat-hither-sync
├── scripts/
│   ├── doctor.sh
│   └── verify-no-leaks.sh
├── completions/
│   ├── hither.bash
│   └── _hither
└── lash.json                    # lash install manifest
```
