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
