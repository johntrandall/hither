# Design Decisions

Why Hither is built the way it is. Each section describes a decision and the alternative it rejected.

## Why `/Hither/` and not `/Network/`

Finder's "Network" sidebar item is a Bonjour browser — a UI affordance for discovering nearby services. The macOS filesystem also has `/Network`, which is autofs's traditional mount root. The two are conceptually unrelated but share a name, and users routinely mix them up. Putting Hither's mounts under `/Network/` would deepen that confusion.

`/Hither/` instead:

- Doesn't collide with any existing Finder UI element.
- Matches macOS's CamelCase root-path convention (`/Applications`, `/Library`, `/System`, `/Volumes`, `/Users`). Apple has not added a lowercase-leading root in any release of macOS to date.
- Is short, memorable, and unique to this tool — easy to grep for in shell history, easy to tab-complete, and impossible to confuse with anything else on the system.

## Why `apfs.util -t` instead of a reboot

To materialize a new `/etc/synthetic.conf` entry, the canonical Apple-documented approach is to reboot. The Nix installer discovered that `apfs.util -t /` triggers the synthetic firmlink materialization without rebooting, and this trick is now used by Nix, Determinate Systems, and several other macOS-provisioning tools.

**Observed** (not Verified) on macOS 15.7.7: `apfs.util -t /` reliably materializes the `Hither` synthetic root within seconds. The bootstrap script uses this path; if it fails, the operator is told to reboot as a fallback. (We have not yet hit a case where `-t` failed; the fallback exists in case Apple changes the behavior in a future macOS release.)

## Why a wrapper script instead of a `tee` sudoers grant

A common pattern for letting a non-root sync script write `/etc/auto_smb_*` is the sudoers grant:

```
<user> ALL=(root) NOPASSWD: /usr/bin/tee /etc/auto_smb_*
```

This is path-traversable. The `*` glob in a sudoers argument position matches any string, including strings containing `/`. So `sudo tee /etc/auto_smb_../passwd` matches the rule and writes to `/etc/passwd`. Any user covered by the grant could obtain arbitrary root file-write.

The wrapper script `hither-write-map` replaces that grant with:

```
%admin ALL=(root) NOPASSWD: /usr/local/sbin/hither-write-map ^[a-z0-9-]+$
```

Inside the wrapper, `argv[1]` is validated against `^[a-z0-9-]+$` before being concatenated into the destination path. No slashes, no dots, no upper case — nothing that could redirect the write outside `/etc/hither_*`. The hole is closed. The `^...$` regex on the sudo side (sudo 1.9.10+) is a defense-in-depth — even if the wrapper had a bug, sudo would refuse to dispatch a non-matching arg.

## Why `ServiceDescription` is a project convention, not Apple-documented

Both Hither plists include a multi-paragraph `ServiceDescription` key. This key is not in the `launchd.plist(5)` man page on macOS 15.7.7, and no Apple-shipped LaunchDaemon uses it.

It is nonetheless useful: third-party launchd UIs (LaunchControl, Lingon) display this field, and the future operator reading the plist gets immediate human context instead of having to grep the surrounding source code. The convention: every Hither plist must include a `ServiceDescription` paragraph explaining what the service does, why it exists, what it depends on, and how to operate it.

Launchd itself ignores the key — there is no functional effect. It is documentation-as-code, embedded where the next person who debugs this daemon will see it.

## Scope of v1: dynamic DSM enumeration only

v1 ships with a single mode: dynamic share enumeration via the Synology DSM Web API. The script logs in as the target DSM user, calls `SYNO.FileStation.List/list_share`, and uses the server-side ACL filter to get exactly the shares that user can read.

Static-curated peer lists (mount a fixed set of SMB shares from a non-DSM host) are deferred past v1.0. The reasons are operational: DSM enumeration is the path the author actually uses, and adding a second mode without an end-user pulling for it adds maintenance surface for no immediate value. v2 may introduce `hither add-peer` for static peers; PRs welcome.

## Daemon constraints (load-bearing)

Two non-obvious rules govern what the LaunchDaemon may and may not do. Both are load-bearing — violating either causes silent failures at boot.

| Rule | Why |
|---|---|
| **NEVER make network calls.** | The daemon runs at boot before networking is up (Wi-Fi association, DHCP, Tailscale, DNS — none of it guaranteed). Any network call (curl, ssh, DNS lookup) will hang or fail. The daemon's only job is to keep local `/etc/` files correct; the LaunchAgent handles share enumeration asynchronously, in user GUI context, after the system is fully up. |
| **NEVER `stat`/`ls`/`cat` under `/Hither/{host}/`.** | Touching a path under an autofs mountpoint triggers a mount attempt. The daemon runs as root, in a launchd context, with no GUI session and no Keychain access. The SMB mount will fail (no credentials), the daemon will hang waiting for it, and the trigger blocks subsequent runs. The daemon may inspect `/etc/auto_master` and `/etc/synthetic.conf` and `/etc/hither_*` directly — but must not cross into the mount-trigger territory beneath `/Hither/`. |

## Runtime data is never committed back

Hither is asymmetric on purpose. Bootstrap scripts, the wrapper, the LaunchDaemon plist, the sync script — all version-controlled. The output of the sync script — `/etc/hither_{host}` files on each Mac — is *runtime data*, not source. It contains live share names and SMB URLs that may include PII (family member names, property names, personal-project names embedded in share paths).

The repo holds **structure**. The live filesystem holds **data**. The `verify-no-leaks.sh` script enforces this boundary by scanning the repo for patterns the operator declares in `~/.config/hither/leak-patterns.txt` — a gitignored file, outside the repo, holding the regex alternation of names that must never appear in a commit.

## Why `/etc/synthetic.conf` is written in symlink form, not directory form

`synthetic.conf` accepts two grammars per `man synthetic.conf`:

- Single-column (`Hither`) creates an empty stub directory at `/Hither`.
- Two-column (`Hither<TAB>System/Volumes/Data/Hither`) creates a symlink at `/Hither` pointing to the given target.

The single-column form looks simpler and was the v0.1.0 default. It is broken in practice. The Sealed System Volume (SSV) on macOS Sequoia mounts `/` read-only after boot; a stub directory created there inherits that read-only property and cannot host autofs mounts. The first `cd /Hither/<nas>/foo` after boot returns a "Read-only file system" error from autofs's mount-trigger machinery.

The two-column symlink form redirects the synthetic root to `/System/Volumes/Data/Hither`, which lives on the writable Data volume. Autofs mounts on that target succeed normally.

This was discovered post-v1 ship: production had been manually edited by the operator to the symlink form, but `bootstrap/add-synthetic-root.sh` still wrote the broken directory form. The v0.1.1 fix aligns the script with the operator's correction so the LaunchDaemon's revert-defender restores the *correct* form if macOS ever wipes `/etc/synthetic.conf`.

## Why bootstrap scripts live at `/usr/local/libexec/hither/`

Earlier prototypes had the LaunchDaemon's `ProgramArguments` invoke `/bin/bash /Users/<name>/dev/hither/bootstrap/add-synthetic-root.sh ...` directly from the dev checkout. That works, but creates two problems:

1. **Mode-700 user home.** On Sequoia, `/Users/<name>/` may be mode 0700 (the default for new accounts). The LaunchDaemon runs as root, so it *can* read; but the dependency on a user-home path is brittle — repo relocation, account rename, FileVault unlock state on first boot, etc., all become potential failure modes for a system service.
2. **Wrong ownership domain.** A root-executed daemon should not depend on files writable by a non-root user. The user could `rm -rf ~/dev/hither/` and silently break the daemon at next fire.

The current layout copies the bootstrap scripts into `/usr/local/libexec/hither/` (root-owned, mode 0755) during `hither bootstrap`, matching the pattern for the root wrapper at `/usr/local/sbin/hither-write-map`. The dev checkout remains the source of truth; `hither bootstrap` is the install step that propagates source → system path.

`/usr/local/libexec/` is the FHS-aligned location for "binaries executed by other programs, not directly by users." It is the right home for daemon-invoked scripts.

## Why a LaunchAgent for sync, not a LaunchDaemon

Three reasons the sync has to be a LaunchAgent (user GUI context) and not a LaunchDaemon (root system context):

1. **Keychain access.** The DSM password lives in macOS Keychain — the same entry Finder's Cmd-K populates for SMB mounts. `security find-internet-password -s <nas> -a <user> -w` reads it. That call requires a GUI security session (`gui/<uid>` launchd domain). Running the sync as a LaunchDaemon was tried and rejected — Keychain calls fail with `errSecAuthFailed (-25293)` under launchd-root, even with the keychain unlocked at the user level.
2. **No external secret store.** Reading from Keychain means no 1Password, no Vault, no Synology Secrets Manager. The user already manages this credential via Finder. We piggyback on it.
3. **No external orchestrator.** A LaunchAgent's `StartCalendarInterval` is per-Mac. It needs nothing outside the Mac to fire on schedule. Missed runs (laptop closed, asleep) catch up on next wake via launchd's normal behavior.

The trade-off: the user must be logged in for the sync to fire. For a personal Mac, that's nearly always true. For a server Mac that's intentionally headless, the sync wouldn't fire — but a headless server Mac doesn't need lazy autofs either; static mounts are fine. The deferred case is small enough to ignore.

Counterpart split: the **defender** stays a LaunchDaemon. It must run at boot before login, must write `/etc/synthetic.conf` and `/etc/auto_master` (which a LaunchAgent cannot), and must not depend on network or Keychain. Two daemons, two contexts, two non-overlapping responsibilities.

## Why credential resolution is env-var-then-Keychain (no 1Password)

`hither-sync.sh` resolves the DSM password in this order:

1. Env var `${NAS_UPPER}_DSM_PASSWORD` — out-of-band override, useful for manual fires.
2. macOS Keychain via `security find-internet-password -s <nas> -a <user> -w`.

That's the whole resolution chain. There's deliberately no `op item get`, no Vault call, no Synology Secrets injection. Hither shipping to strangers must not require a particular secret manager — operators who want one can inject via the env-var path:

```bash
MYNAS_DSM_PASSWORD=$(op read 'op://Personal/mynas/password') hither sync
```

The env-var path is the universal-interface escape hatch. Routine sync (LaunchAgent fire) goes Keychain-only.

## Why a `.needs-reload` marker file on automount failure

The v0.1.0 wrapper had a subtle stuck-state bug. The sync script's diff comparison (`current_body == desired_body`) is between the on-disk map and the desired map. If `mv -f tmp target` succeeded but `automount -cv` failed afterward, the on-disk file matched the desired content — so the *next* sync run saw `current == desired` and skipped re-invocation entirely. The autofs cache stayed stale until the Mac rebooted.

The v0.1.1 wrapper writes `/etc/hither_${host}.needs-reload` (root-owned, 644) when `automount -cv` fails after a successful map write. `hither-sync.sh::apply_map_if_changed` checks for the marker BEFORE the diff comparison. If present, the wrapper is re-invoked unconditionally — which gives `automount -cv` another shot. The success path clears the marker. So the next-sync horizon for recovering from a transient autofs hiccup is the regular cadence (daily) rather than the next reboot.

Alternative considered and rejected: bumping the on-disk file's mtime via `touch`. That changes nothing autofs observes — autofs reloads on `automount -cv`, not on file-mtime — so it wouldn't actually help. A marker file checked by the script that *does* invoke `automount -cv` is the cleanest path.
