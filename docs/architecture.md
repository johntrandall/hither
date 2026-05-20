# Architecture

Hither is a two-sided system: a scheduling layer that fires per-host events, and a client-side configuration that makes shares appear at stable paths on each Mac.

## Server side — Conductor on Umbridge, workers on each Mac

Hither uses the xyOps "pull from Forgejo at pinned SHA" pattern. The Conductor on Umbridge schedules; the work executes on each subscriber Mac via its xysat worker. There is no SSH-out from Umbridge to the Macs.

| Component | Detail |
|---|---|
| Scheduler | xyOps event `hither-sync-{host}`, daily at 04:{schedule_minute} ET |
| Target | The Mac's xysat `server_id` (per-event, NOT category default) |
| Runner | `server/hither-sync.sh` — fetched on each fire from Forgejo at the pinned SHA |
| Run-as user | The xysat worker user on the Mac (`infra-agent`) |
| Catch-up | `catch_up: true` — asleep at fire time runs on next reconnect, no missed runs |
| Credential | Per-NAS DSM password injected via xyOps Secret (`{NAS_UPPER}_DSM_PASSWORD`) |

The sync flow:

1. The xyOps event fires at 04:{schedule_minute} ET (per-host minute, low-priority window).
2. The Mac's xysat worker receives the fire and runs the **wrapper** stored in the event's `params.script`.
3. The wrapper `curl`s `hither-sync.sh` from Forgejo at the pinned SHA (using a readonly Forgejo token injected as the xyOps secret `forgejo-ro-admin-technical`), saves it to a tempfile, `chmod +x`, and `exec`s it with `TARGET_USER` and `NAS_LIST` exported. `NAS_PROTO` (default `http`) and `OP_VAULT` (default `JRVIS Infra`) are not exported by the wrapper; they fall back to the defaults in `hither-sync.sh`.
4. `hither-sync.sh` calls the DSM Web API as the target user (`SYNO.FileStation.List/list_share`) — the server-side ACL filter returns exactly the shares that user can read.
5. The script renders the share list as an autofs indirect-map body.
6. It diffs against the on-disk `/etc/hither_{nas}`. If unchanged: no-op. If changed: pipes the body into `sudo -n /usr/local/sbin/hither-write-map {host}`.
7. The wrapper validates the hostname argument against `^[a-z0-9-]+$`, atomically writes `/etc/hither_{host}`, and runs `automount -cv` to pick up the change.

The registration script (`server/register-events.sh`) creates and updates the per-host events from `hither-sync.manifest.json`. Subscribers are listed in the manifest's `hosts` array.

## Client side (each Mac)

Three pieces of system state on the Mac, each managed by a different bootstrap step:

| State | Path | Source | Frequency |
|---|---|---|---|
| Synthetic root | `/etc/synthetic.conf` line: `Hither\tSystem/Volumes/Data/Hither` (symlink form) | `bootstrap/add-synthetic-root.sh` | One-shot; re-applied by daemon on revert |
| Autofs mountpoints | `/etc/auto_master` lines: `/Hither/{host}\thither_{host}\t-nosuid` | `bootstrap/apply-auto-master.sh` | One-shot per subscribed host; re-applied by daemon on revert |
| Autofs maps | `/etc/hither_{host}` | xysat worker (via wrapper) | Daily, regenerated only when content changes |

The first two pieces are structural — once set up, they only change when subscribing to a new host or recovering from a macOS update revert. The third piece is data — regenerated daily by the local xysat run.

## LaunchDaemon

`/Library/LaunchDaemons/com.johnrandall.hither.bootstrap.plist` runs at boot and on file-system trigger:

- **RunAtLoad**: re-applies synthetic.conf and auto_master at every boot.
- **WatchPaths**: monitors `/etc/auto_master` and `/etc/synthetic.conf` for modification. If macOS updates strip Hither's lines, the daemon re-adds them.

The daemon NEVER does network calls (it must run before Tailscale is up at boot) and NEVER stats anything under `/Hither/{host}/`. See [design-decisions.md](design-decisions.md) for why these constraints are load-bearing.

## Wrapper

`/usr/local/sbin/hither-write-map` is the only piece of Hither that runs as root in normal operation. It is installed from `sbin/hither-write-map` in this repo.

Its job is exactly this:

1. Validate `argv[1]` against `^[a-z0-9-]+$`. Reject anything else.
2. Read map body from stdin into a tempfile in `/etc/`.
3. `mv` the tempfile to `/etc/hither_{host}` (atomic rename within the same filesystem).
4. Run `automount -cv` to flush the autofs cache.

The hostname whitelist is the security boundary. The original sudoers grant — `infra-agent ALL=(root) NOPASSWD: /usr/bin/tee /etc/auto_smb_*` — was path-traversable because `*` in a sudo argument position matches `/`, allowing arbitrary file writes. The wrapper closes that hole.

## Data flow

```mermaid
sequenceDiagram
    participant XY as xyOps Conductor (Umbridge)
    participant XS as xysat worker (Mac)
    participant FJ as Forgejo (umbridge:8914)
    participant SH as hither-sync.sh (local tmpfile)
    participant DSM as DSM API (umbridge:5000)
    participant W as hither-write-map (root)
    participant ETC as /etc/hither_umbridge
    participant AF as automountd
    participant USR as User shell

    Note over XY: 04:{minute} daily
    XY->>XS: fire hither-sync-{host} on target server_id
    XS->>FJ: curl pinned-SHA script with token
    FJ-->>XS: hither-sync.sh body
    XS->>SH: chmod +x; exec with TARGET_USER, NAS_LIST
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

The data flow is **one-way**: repo → Mac `/etc/`, never Mac `/etc/` → repo. The live `/etc/hither_{host}` files contain actual share names which may include family/PII data; they are never committed. The repo holds structure (bootstrap scripts, wrapper, LaunchDaemon, the sync job source). The live state holds data.
