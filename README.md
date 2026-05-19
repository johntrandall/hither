# Hither

**Bring it here. A lazy mounter for personal Mac fleets.**

Hither manages autofs maps so that remote SMB shares appear at predictable, stable paths under `/Hither/{host}/{share}` on every Mac in the fleet, with a LaunchDaemon that defends the system configuration against macOS update reverts.

## What this is

Apple's autofs is great when it works and miserable when it doesn't. macOS system updates routinely wipe `/etc/auto_master`, which silently breaks every indirect map on the machine until somebody notices that `cd /Network/foo` no longer triggers a mount. The historical workaround — a `sudoers` grant for `tee /etc/auto_smb_*` — turned out to be path-traversable (the `*` wildcard in a sudo argument matches `/`), making the convenience a security hole. And the `/Network` filesystem path conceptually collides with Finder's "Network" sidebar item, which is actually a Bonjour browser — confusing users who don't realize they're looking at two different things wearing the same name.

Hither addresses all three problems. It mounts under `/Hither/` instead of `/Network/`, sidestepping the Finder naming clash and matching macOS's CamelCase root convention (`/Applications`, `/Library`, `/Volumes`). It uses a root-owned wrapper script with a strict `^[a-z0-9-]+$` host-name whitelist instead of a sudoers wildcard, closing the path-traversal hole. And it ships a LaunchDaemon that watches `/etc/auto_master` and `/etc/synthetic.conf`, re-applying Hither's lines whenever an OS update reverts them.

On the server side, a daily xyOps event fires per subscriber Mac. The Conductor (on Umbridge) schedules; the work executes on the Mac itself — its xysat worker pulls `hither-sync.sh` from Forgejo at a pinned SHA, enumerates DSM's SMB-accessible shares via the DSM Web API, and writes the regenerated autofs map locally. On the client side, autofs handles everything else: shares mount on access, unmount on idle, and the user never sees the wiring.

## Architecture

```mermaid
flowchart LR
    subgraph Conductor["Umbridge (xyOps Conductor)"]
        XY[xyOps event: daily 04:XX]
        FJ[Forgejo: pinned-SHA script]
        DSM[DSM Web API]
    end

    subgraph Client["Each subscriber Mac"]
        XS[xysat worker as infra-agent]
        SH[hither-sync.sh in /tmp]
        WRAP[/usr/local/sbin/hither-write-map]
        ETC[/etc/hither_umbridge]
        AM[/etc/auto_master]
        SC[/etc/synthetic.conf]
        AUTOFS[automountd]
        USER[User: cd /Hither/umbridge/share]
        XS --> SH
        SH --> WRAP
        WRAP --> ETC
        ETC --> AUTOFS
        AM --> AUTOFS
        SC --> AUTOFS
        USER --> AUTOFS
    end

    XY -- "fire event on target server_id" --> XS
    XS -- "curl pinned-SHA script" --> FJ
    SH -- "list_share as TARGET_USER" --> DSM
```

## Install

Hither is private during v1 — no Homebrew tap yet. Install from a local clone:

```bash
git clone <forgejo-umbridge:dev/hither.git> ~/dev/hither
cd ~/dev/hither
lash install
sudo "$(which hither)" bootstrap
```

`bootstrap` performs four steps, in this order:

1. Adds the `Hither` synthetic-root symlink entry to `/etc/synthetic.conf` and materializes `/Hither` (via `apfs.util -t`).
2. Applies the initial `/etc/auto_master` entries for each subscribed host (currently: `umbridge`).
3. Installs the root-owned wrapper `sbin/hither-write-map` to `/usr/local/sbin/hither-write-map`.
4. Installs and loads the LaunchDaemon at `/Library/LaunchDaemons/com.johnrandall.hither.bootstrap.plist`.

`bootstrap --reapply-only` skips steps 3 and 4 (file install). It is what the LaunchDaemon itself runs at boot / on WatchPaths trigger.

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
│   ├── add-synthetic-root.sh    # installs to /usr/local/libexec/hither/; appends "Hither<TAB>System/Volumes/Data/Hither" to /etc/synthetic.conf
│   ├── apply-auto-master.sh     # installs to /usr/local/libexec/hither/; appends /Hither/{host} lines to /etc/auto_master
│   └── install-launchdaemon.sh  # installs the plist to /Library/LaunchDaemons/
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
