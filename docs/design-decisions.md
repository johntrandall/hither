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

The original implementation used:

```
infra-agent ALL=(root) NOPASSWD: /usr/bin/tee /etc/auto_smb_*
```

This is path-traversable. The `*` glob in a sudoers argument position matches any string, including strings containing `/`. So `sudo tee /etc/auto_smb_../passwd` matches the rule and writes to `/etc/passwd`. Any user with `infra-agent` privileges (which on a personal Mac fleet means: anyone who can SSH from the NAS) could obtain root file-write.

The wrapper script `hither-write-map` replaces that grant with:

```
infra-agent ALL=(root) NOPASSWD: /usr/local/sbin/hither-write-map
```

Inside the wrapper, `argv[1]` is validated against `^[a-z0-9-]+$` before being concatenated into the destination path. No slashes, no dots, no upper case — nothing that could redirect the write outside `/etc/hither_*`. The hole is closed.

## Why `ServiceDescription` is a project convention, not Apple-documented

The LaunchDaemon plist at `launchd/com.johnrandall.hither.bootstrap.plist` includes a multi-paragraph `ServiceDescription` key. This key is not in the `launchd.plist(5)` man page on macOS 15.7.7, and no Apple-shipped LaunchDaemon uses it.

It is nonetheless required by the user-global `launchd-service-description` project skill: every John-authored LaunchDaemon must include a `ServiceDescription` paragraph explaining what the service does, why it exists, what it depends on, and how to operate it. Third-party UIs (LaunchControl, Lingon) display this field; future-John reading the plist gets immediate human context instead of having to read source code.

Launchd itself ignores the key — there is no functional effect. It is documentation-as-code, embedded where the next person who debugs this daemon will see it.

## Why scope v1 to Umbridge only (defer Hedwig)

Two reasons to defer multi-NAS support:

1. **Umbridge is a Synology**; Hedwig is a Mac running SMB. The xyOps job enumerates shares via the DSM Web API. That API does not exist on Hedwig. Hedwig would require a different mode — a static curated peer-list rather than dynamic enumeration.
2. **No demand yet.** John mounts Hedwig shares maybe twice a quarter, manually. The cost of building peer-list mode now exceeds the operational value.

v2 will introduce `hither add-peer` for static-curated SMB peers. v1 ships with the DSM-enumeration path only.

## Why the repo is PRIVATE for v1

Live `/etc/hither_umbridge` content includes family-member names in share-paths (e.g. `MediaLTArchive`, names of properties, names of household projects). Even though the *repo* never contains the live files, the structure and bootstrap scripts hint at the topology, and the temptation to paste a sample map into an issue or commit message is real.

Sanitizing for public release would be a 2-3 hour effort: scrubbing example output, generalizing hostnames, adding redaction guidance to the contribution guide. That effort distracts from the operational value Hither provides today. Defer until either (a) someone external asks for it, or (b) the multi-NAS abstraction in v2 forces a documentation rewrite anyway.

## Why no Homebrew tap for v1

Same calculus as the PRIVATE-repo decision. A `brew tap johntrandall/hither` would be the right install path for a public release. For a single-developer fleet of four Macs, `git clone && lash install` is sufficient and adds no operational complexity. Deferred along with the public-release work.

## Daemon constraints (load-bearing)

Two non-obvious rules govern what the LaunchDaemon may and may not do. Both are load-bearing — violating either causes silent failures at boot.

| Rule | Why |
|---|---|
| **NEVER make network calls.** | The daemon runs at boot before Tailscale is up. Any network call (curl, ssh, DNS lookup of an external host) will hang or fail. The daemon's only job is to keep local `/etc/` files correct; the server-side sync handles map updates separately, asynchronously, via xyOps. |
| **NEVER `stat`/`ls`/`cat` under `/Hither/{host}/`.** | Touching a path under an autofs mountpoint triggers a mount attempt. The daemon runs as root, in a launchd context, with no GUI session and no Keychain access. The SMB mount will fail (no credentials), the daemon will hang waiting for it, and the trigger blocks subsequent runs. The daemon may inspect `/etc/auto_master` and `/etc/synthetic.conf` and `/etc/hither_*` directly — but must not cross into the mount-trigger territory beneath `/Hither/`. |

## Runtime data is never committed back

Hither is asymmetric on purpose. Bootstrap scripts, the wrapper, the LaunchDaemon plist, the sync script — all version-controlled. The output of the sync script — `/etc/hither_{host}` files on each Mac — is *runtime data*, not source. It contains live share names and SMB URLs that may include PII.

The repo holds **structure**. The live filesystem holds **data**. The `verify-no-leaks.sh` script enforces this boundary by scanning the repo for patterns that look like committed live-map content.

## Why `/etc/synthetic.conf` is written in symlink form, not directory form

`synthetic.conf` accepts two grammars per `man synthetic.conf`:

- Single-column (`Hither`) creates an empty stub directory at `/Hither`.
- Two-column (`Hither<TAB>System/Volumes/Data/Hither`) creates a symlink at `/Hither` pointing to the given target.

The single-column form looks simpler and was the v0.1.0 default. It is broken in practice. The Sealed System Volume (SSV) on macOS Sequoia mounts `/` read-only after boot; a stub directory created there inherits that read-only property and cannot host autofs mounts. The first `cd /Hither/umbridge/foo` after boot returns a "Read-only file system" error from autofs's mount-trigger machinery.

The two-column symlink form redirects the synthetic root to `/System/Volumes/Data/Hither`, which lives on the writable Data volume. Autofs mounts on that target succeed normally.

This was discovered post-v1 ship: production had been manually edited by the operator to the symlink form, but `bootstrap/add-synthetic-root.sh` still wrote the broken directory form. The v0.1.1 fix aligns the script with the operator's correction so the LaunchDaemon's revert-defender restores the *correct* form if macOS ever wipes `/etc/synthetic.conf`.

## Why bootstrap scripts live at `/usr/local/libexec/hither/`

The v0.1.0 LaunchDaemon `ProgramArguments` invoked `/bin/bash /Users/johnrandall/dev/hither/bootstrap/add-synthetic-root.sh ...`. That works, but creates two problems:

1. **Mode-700 user home.** On Sequoia, `/Users/johnrandall/` may be mode 0700 (the default for new accounts on this version). The LaunchDaemon runs as root, so it can read; but the dependency on a user-home path is brittle — repo relocation, account rename, FileVault unlock state on first boot, etc., all become potential failure modes for a system service.
2. **Wrong ownership domain.** A root-executed daemon should not depend on files writable by a non-root user. The user could `rm -rf ~/dev/hither/` and silently break the daemon at next fire.

The v0.1.1 layout copies the bootstrap scripts into `/usr/local/libexec/hither/` (root-owned, mode 0755) during `hither bootstrap`, matching the existing pattern for the root wrapper at `/usr/local/sbin/hither-write-map`. The repo at `~/dev/hither/` remains the source of truth; `hither bootstrap` is the install step that propagates source → system path.

`/usr/local/libexec/` is the FHS-aligned location for "binaries executed by other programs, not directly by users." It is the right home for daemon-invoked scripts.

## Why a LaunchAgent for sync, not a LaunchDaemon (v0.2.0)

v0.1.x ran the daily share-enumeration via xyOps — the Conductor on Umbridge fired a per-Mac event daily, the Mac's xysat worker pulled the script from Forgejo at a pinned SHA, and ran it as the `infra-agent` service account. The credential model layered xyOps Secret injection (`${NAS_UPPER}_DSM_PASSWORD`) on top of a 1Password fallback (`op item get`).

That worked, but it was wrong for a distributable tool. Per the v0.2 → v1.0 roadmap's design north star: **Hither must be a self-contained per-Mac tool.** A stranger should be able to `brew install johntrandall/hither/hither` and have working lazy-mounted SMB shares — without setting up xyOps, without a Synology Conductor, without a 1Password vault. Anything that requires an external orchestrator is wrong for the packaged tool.

v0.2.0 drops the external orchestration and replaces it with a per-Mac LaunchAgent. Three reasons it has to be a LaunchAgent and not a LaunchDaemon:

1. **Keychain access.** The DSM password lives in macOS Keychain — the same entry Finder's Cmd-K populates for SMB mounts. `security find-internet-password -s <nas> -a <user> -w` reads it. That call requires a GUI security session (`gui/<uid>` launchd domain). Running the sync as a LaunchDaemon was tried and rejected — Keychain calls fail with `errSecAuthFailed (-25293)` under launchd-root, even with the keychain unlocked at the user level. (See `feedback-keychain-fails-under-launchd.md` in the operator's memory.)
2. **No external secret store.** Reading from Keychain means no 1Password, no xyOps Secret, no Vault-style server. The user already manages this credential via Finder. We piggyback on it.
3. **No external orchestrator.** A LaunchAgent's `StartCalendarInterval` is per-Mac. It needs nothing outside the Mac to fire on schedule. Catch-up on resume is handled by launchd's normal behavior.

The trade-off: the user must be logged in for the sync to fire. For a personal Mac, that's nearly always true. For a server Mac that's intentionally headless, the sync wouldn't fire — but a server Mac doesn't need lazy autofs either; static mounts are fine. The deferred case is small enough to ignore.

Counterpart split: the **defender** stays a LaunchDaemon. It must run at boot before login, must write `/etc/synthetic.conf` and `/etc/auto_master` (which a LaunchAgent cannot), and must not depend on network or Keychain. Two daemons, two contexts, two non-overlapping responsibilities.

## Why drop the 1Password fallback (v0.2.0)

v0.1.x's `dsm_login` resolved credentials in this order: env-var → `$DSM_PASSWORD` → `op item get`. The `op` fallback was useful when manual-fired from John's shell (his 1P session was active), but irrelevant on the production sync path (the xysat worker ran as `infra-agent` with no 1P session).

v0.2.0 drops the `op` fallback entirely. The env-var override is preserved (it lets the operator do `UMBRIDGE_DSM_PASSWORD=$(op read ...) hither sync` for manual fires). Routine sync goes Keychain-only.

The architectural argument: Hither shipping to strangers must not require 1Password. Keeping the `op` code path branched — with comments explaining when it does and doesn't apply — adds maintenance surface and confuses readers. Strip it. Operators who want 1P can inject via env-var, which is the universal-interface escape hatch.

## Why a `.needs-reload` marker file on automount failure

The v0.1.0 wrapper had a subtle stuck-state bug. The sync script's diff comparison (`current_body == desired_body`) is between the on-disk map and the desired map. If `mv -f tmp target` succeeded but `automount -cv` failed afterward, the on-disk file matched the desired content — so the *next* sync run saw `current == desired` and skipped re-invocation entirely. The autofs cache stayed stale until the Mac rebooted.

The v0.1.1 wrapper writes `/etc/hither_${host}.needs-reload` (root-owned, 644) when `automount -cv` fails after a successful map write. `hither-sync.sh::apply_map_if_changed` checks for the marker BEFORE the diff comparison. If present, the wrapper is re-invoked unconditionally — which gives `automount -cv` another shot. The success path clears the marker. So the next-sync horizon for recovering from a transient autofs hiccup is the regular cadence (daily) rather than the next reboot.

Alternative considered and rejected: bumping the on-disk file's mtime via `touch`. That changes nothing autofs observes — autofs reloads on `automount -cv`, not on file-mtime — so it wouldn't actually help. A marker file checked by the script that *does* invoke `automount -cv` is the cleanest path.
