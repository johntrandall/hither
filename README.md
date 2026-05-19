# Hither

**Bring it here. A lazy mounter for personal Mac fleets.**

Hither manages autofs maps so that remote SMB shares appear at predictable, stable paths under `/Hither/{host}/{share}` on every Mac in the fleet, with a LaunchDaemon that defends the system configuration against macOS update reverts.

## What this is

Apple's autofs is great when it works and miserable when it doesn't. macOS system updates routinely wipe `/etc/auto_master`, which silently breaks every indirect map on the machine until somebody notices that `cd /Network/foo` no longer triggers a mount. The historical workaround — a `sudoers` grant for `tee /etc/auto_smb_*` — turned out to be path-traversable (the `*` wildcard in a sudo argument matches `/`), making the convenience a security hole. And the `/Network` filesystem path conceptually collides with Finder's "Network" sidebar item, which is actually a Bonjour browser — confusing users who don't realize they're looking at two different things wearing the same name.

Hither addresses all three problems. It mounts under `/Hither/` instead of `/Network/`, sidestepping the Finder naming clash and matching macOS's CamelCase root convention (`/Applications`, `/Library`, `/Volumes`). It uses a root-owned wrapper script with a strict `^[a-z0-9-]+$` host-name whitelist instead of a sudoers wildcard, closing the path-traversal hole. And it ships a LaunchDaemon that watches `/etc/auto_master` and `/etc/synthetic.conf`, re-applying Hither's lines whenever an OS update reverts them.

On the server side, a daily xyOps job on the Synology NAS enumerates DSM's SMB-accessible shares and pushes a freshly generated autofs map to each subscriber Mac. On the client side, autofs handles everything else: shares mount on access, unmount on idle, and the user never sees the wiring.

## Architecture

```mermaid
flowchart LR
    subgraph Server["Umbridge (Synology NAS)"]
        XY[xyOps: daily 04:00]
        SYNC[server/hither-sync.sh]
        DSM[DSM API]
        XY --> SYNC
        SYNC --> DSM
    end

    subgraph Client["Each subscriber Mac"]
        WRAP[/usr/local/sbin/hither-write-map]
        ETC[/etc/hither_umbridge]
        AM[/etc/auto_master]
        SC[/etc/synthetic.conf]
        AUTOFS[automountd]
        USER[User: cd /Hither/umbridge/share]
        WRAP --> ETC
        ETC --> AUTOFS
        AM --> AUTOFS
        SC --> AUTOFS
        USER --> AUTOFS
    end

    SYNC -- "ssh + sudo -n wrapper" --> WRAP
```

## Install

Hither is private during v1 — no Homebrew tap yet. Install from a local clone:

```bash
git clone <forgejo-umbridge:dev/hither.git> ~/dev/hither
cd ~/dev/hither
lash install
sudo "$(which hither)" bootstrap
```

`bootstrap` performs three steps:

1. Adds the `Hither` synthetic root to `/etc/synthetic.conf` and materializes it (via `apfs.util -t`).
2. Installs the LaunchDaemon at `/Library/LaunchDaemons/com.johnrandall.hither.bootstrap.plist`.
3. Applies the initial `/etc/auto_master` entries for each subscribed host.

## Verify

```bash
hither doctor
hither verify-no-leaks
```

`doctor` reports the state of the three pieces of system configuration (synthetic root, auto_master entries, hither_* map files) and confirms the LaunchDaemon is loaded. `verify-no-leaks` checks that no live share-path or PII data has been committed back into the repo.

## Sub-projects

| Document | Purpose |
|---|---|
| [docs/architecture.md](docs/architecture.md) | Detailed architecture: server side, client side, data flow |
| [docs/design-decisions.md](docs/design-decisions.md) | Why this design — the alternatives considered and rejected |
| [docs/glossary.md](docs/glossary.md) | Terms (xyOps, autofs, lash, etc.) for non-John readers |
| [server/](server/) | xyOps job manifest and `hither-sync.sh` (runs on Umbridge) |

The architectural rationale for adopting Hither across the fleet — and superseding the prior `auto_smb_*` sudoers scheme — lives in `admin-technical/ADRs/ADR-NNN-Hither-Lazy-Mounter.md` (TBD).

## File layout

```
hither/
├── README.md                    # this file
├── docs/
│   ├── architecture.md          # detailed architecture
│   ├── design-decisions.md      # rationale
│   └── glossary.md              # terms for non-John readers
├── bin/
│   └── hither                   # CLI (bootstrap, doctor, verify-no-leaks, version)
├── sbin/
│   └── hither-write-map         # root-owned wrapper, installed at /usr/local/sbin/
├── bootstrap/
│   ├── add-synthetic-root.sh    # /etc/synthetic.conf: append "Hither"
│   ├── apply-auto-master.sh     # /etc/auto_master: append /Hither/{host} lines
│   └── install-launchdaemon.sh  # /Library/LaunchDaemons/com.johnrandall.hither.bootstrap.plist
├── launchd/
│   └── com.johnrandall.hither.bootstrap.plist   # LaunchDaemon with ServiceDescription
├── server/
│   ├── hither-sync.sh           # runs on Umbridge under xyOps
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
