# Architecture

Hither is a self-contained per-Mac tool. There is no Hither server. Two daemons on each Mac, with non-overlapping responsibilities split by privilege/context, handle everything.

## Two daemons

| Daemon | Type | Context | Role | Network? |
|---|---|---|---|---|
| `com.johnrandall.hither.bootstrap` | LaunchDaemon | root | Re-apply `/etc/synthetic.conf` + `/etc/auto_master` on revert; RunAtLoad + WatchPaths | never — runs before Tailscale/Wi-Fi |
| `com.johnrandall.hither.sync` | LaunchAgent | user GUI | Daily DSM API call → render map → write via `hither-write-map`; on-demand via `hither sync` | yes |

The privilege/context split is load-bearing:

- **The defender must run as root.** It writes to `/etc/synthetic.conf` and `/etc/auto_master`. It cannot run as a LaunchAgent because LaunchAgents have no write access to `/etc/`.
- **The sync must run in user GUI context.** It calls `security find-internet-password` to read the DSM password from Keychain. Keychain access requires a GUI security session (`gui/<uid>` launchd domain). Running this work as a LaunchDaemon was tried and rejected — Keychain calls fail with `errSecAuthFailed (-25293)` under launchd-root.
- **The defender must do no network calls.** It runs at boot, before Tailscale is up. A network call would hang or fail.
- **The sync may rely on network.** It runs at 04:23 local time, after Tailscale/Wi-Fi is fully up. Catch-up on resume is handled by launchd's normal StartCalendarInterval semantics (missed runs fire on next wake).

## Client-side state

Three pieces of system state on the Mac, each managed by a different bootstrap step:

| State | Path | Source | Frequency |
|---|---|---|---|
| Synthetic root | `/etc/synthetic.conf` line: `Hither\tSystem/Volumes/Data/Hither` (symlink form) | `bootstrap/add-synthetic-root.sh` | One-shot; re-applied by defender on revert |
| Autofs mountpoints | `/etc/auto_master` lines: `/Hither/{host}\thither_{host}\t-nosuid` | `bootstrap/apply-auto-master.sh` | One-shot per subscribed host; re-applied by defender on revert |
| Autofs maps | `/etc/hither_{host}` | LaunchAgent → `hither-sync.sh` → `hither-write-map` | Daily, regenerated only when content changes |

The first two are structural. The third is data, regenerated daily.

## Sync flow

1. LaunchAgent fires at 04:23 local. (Or operator runs `hither sync`, or `launchctl kickstart gui/$(id -u)/com.johnrandall.hither.sync`.)
2. `hither-sync.sh` resolves the DSM password for each NAS in `NAS_LIST`:
   - If `${NAS_UPPER}_DSM_PASSWORD` is set in the env, use it (override path — typical use: `UMBRIDGE_DSM_PASSWORD=$(op read ...) hither sync`).
   - Otherwise, `security find-internet-password -s <nas> -a <TARGET_USER> -w` reads the password from Keychain. This is the same Keychain entry Finder Cmd-K populates for the SMB mount itself.
3. `hither-sync.sh` calls the DSM Web API as the target user (`SYNO.API.Auth/login` → `SYNO.FileStation.List/list_share`) — the server-side ACL filter returns exactly the shares that user can read.
4. The script renders the share list as an autofs indirect-map body.
5. It diffs against the on-disk `/etc/hither_{nas}`. If unchanged: no-op. If changed: pipes the body into `sudo -n /usr/local/sbin/hither-write-map {host}`.
6. The wrapper validates the hostname argument against `^[a-z0-9-]+$`, atomically writes `/etc/hither_{host}`, and runs `automount -cv` to pick up the change.

The whole flow happens on one Mac. No Conductor, no Forgejo, no external secret store.

## Wrapper

`/usr/local/sbin/hither-write-map` is the only piece of Hither that runs as root during normal operation. It is installed from `sbin/hither-write-map` in this repo.

Its job is exactly this:

1. Validate `argv[1]` against `^[a-z0-9-]+$`. Reject anything else.
2. Read map body from stdin into a tempfile in `/etc/`.
3. `mv` the tempfile to `/etc/hither_{host}` (atomic rename within the same filesystem).
4. Run `automount -cv` to flush the autofs cache.

The hostname whitelist is the security boundary. The original sudoers grant — `infra-agent ALL=(root) NOPASSWD: /usr/bin/tee /etc/auto_smb_*` — was path-traversable because `*` in a sudo argument position matches `/`, allowing arbitrary file writes. The wrapper closes that hole.

## Data flow

```mermaid
sequenceDiagram
    participant LA as LaunchAgent (com.johnrandall.hither.sync)
    participant SH as hither-sync.sh (user shell)
    participant KC as macOS Keychain
    participant DSM as DSM API (umbridge:5000)
    participant W as hither-write-map (root, via sudo -n)
    participant ETC as /etc/hither_umbridge
    participant AF as automountd
    participant USR as User shell

    Note over LA: 04:23 daily, gui/<uid>
    LA->>SH: exec /usr/local/libexec/hither/hither-sync.sh
    SH->>KC: security find-internet-password -s umbridge -a johntrandall -w
    KC-->>SH: <password>
    SH->>DSM: SYNO.API.Auth login as TARGET_USER
    DSM-->>SH: SID
    SH->>DSM: SYNO.FileStation.List/list_share
    DSM-->>SH: shares visible to TARGET_USER
    SH->>SH: render map; diff vs /etc/hither_umbridge
    alt changed
      SH->>W: sudo -n; pipe map body; arg=umbridge
      W->>ETC: validate host; atomic mv
      W->>AF: automount -cv
    else unchanged
      SH->>SH: no-op
    end
    Note over USR: hours later
    USR->>AF: cd /Hither/umbridge/Media
    AF->>ETC: lookup "Media" in map
    ETC-->>AF: smb://umbridge/Media + opts
    AF-->>USR: mounted at /Hither/umbridge/Media
```

The data flow is **one-way**: NAS API → local `/etc/`. The live `/etc/hither_{host}` files contain actual share names which may include family/PII data; they are never committed back. The repo holds structure (bootstrap scripts, wrapper, LaunchDaemon plist, LaunchAgent plist template, the sync script source). The live state holds data.

## Defender flow

The LaunchDaemon (`com.johnrandall.hither.bootstrap`) runs at boot and on file-system trigger:

- **RunAtLoad**: re-applies synthetic.conf and auto_master at every boot.
- **WatchPaths**: monitors `/etc/auto_master` and `/etc/synthetic.conf` for modification. If macOS updates strip Hither's lines, the daemon re-adds them.

The daemon NEVER does network calls and NEVER stats anything under `/Hither/{host}/`. See [design-decisions.md](design-decisions.md) for why these constraints are load-bearing.
