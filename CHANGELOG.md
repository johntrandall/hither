# Changelog

## [0.1.1] — 2026-05-19

Hardening pass after a 5-agent verification review of the live SusanBones deployment. System was healthy in production; this release lands the P0 fix and the P1 bundle so the daemon can defend the system without operator intervention if macOS strips state.

### Fixed
- **P0** `bootstrap/add-synthetic-root.sh` now writes the two-column symlink form (`Hither<TAB>System/Volumes/Data/Hither`) — the prior single-column directory form created a stub at `/Hither` that cannot host autofs mounts on a sealed system volume. Production already has the symlink form because the operator hand-edited it post-install; this change guarantees the LaunchDaemon's revert defender restores the correct form if macOS ever wipes `/etc/synthetic.conf`. Idempotency check inverted: symlink form is now `[skip]` (correct), legacy directory form is `[warn]`.
- `bootstrap/apply-auto-master.sh` lock acquire now checks for a stale lock dir older than 5 minutes and breaks it. Recovers from a SIGKILL'd prior run without manual intervention.
- `sbin/hither-write-map` now writes a `/etc/hither_${host}.needs-reload` marker if `automount -cv` fails after a successful map write. `hither-sync.sh` checks the marker before its diff comparison and re-invokes the wrapper unconditionally if present, so a transient autofs failure no longer leaves stale state until reboot.
- `server/register-events.sh` wrapper template now sets `trap 'rm -f "$TMP"' EXIT` so the curl'd script tempfile is cleaned on failure paths.
- `scripts/verify-no-leaks.sh` no longer fail-opens when the patterns file is missing. Default is fail-closed (exit 2) with a setup hint; CI / sandboxed environments opt out via `HITHER_LEAK_PATTERNS_OPTIONAL=1`.

### Changed
- LaunchDaemon plist no longer references a user-home repo path. `bin/hither bootstrap` now installs the bootstrap scripts to `/usr/local/libexec/hither/{add-synthetic-root,apply-auto-master}.sh` (root-owned, mode 0755). The plist's `ProgramArguments` invokes those system paths. Eliminates the mode-700 user-home dependency and matches the wrapper's `/usr/local/sbin/` install pattern.
- `install-launchdaemon.sh` detects plist content changes and runs `bootout` + `bootstrap` to reload, instead of silently no-op'ing when a stale plist is already loaded.
- `docs/architecture.md` rewritten to reflect the actual deployed model: xysat satellites on each Mac pull `hither-sync.sh` from Forgejo at a pinned SHA and run it locally; the Conductor on Umbridge schedules but does not execute. Prior doc described an SSH-from-Synology model that has never been deployed.
- README's bootstrap steps reordered to match `bin/hither` code order (synthetic.conf → auto_master → wrapper → LaunchDaemon).
- `server/register-events.sh` stale comment/log strings referencing `admin-technical` updated to `dev/hither`. The xyOps secret name `forgejo-ro-admin-technical` is retained as a real resource name; clarifying comment added.

### Documented
- `server/sudoers/xysat-hither-sync` now includes a paragraph explaining that the `^[a-z0-9-]+$` argument form is a regex (sudo ≥ 1.9.10 feature) — two independent verifiers misread it as a fnmatch pattern. Empirically working on macOS Sequoia (sudo 1.9.13p2).

## [0.1.0] — 2026-05-19

Initial private import of Hither (v1).

### Added
- CLI: `hither bootstrap`, `hither doctor`, `hither verify-no-leaks`, `hither version`
- Wrapper: `/usr/local/sbin/hither-write-map` — root-owned, arg-validated, atomic-write, runs `automount -cv` internally. Closes path-traversal vulnerability of prior `tee /etc/auto_smb_*` sudoers wildcard.
- LaunchDaemon: `com.johnrandall.hither.bootstrap` — re-applies `/etc/auto_master` + `/etc/synthetic.conf` state at boot and on WatchPaths trigger. Defends against macOS update reverts (motivating incident: macOS 15.7.7 on 2026-05-15 wiped `/Network/umbridge` and `/Network/hedwig` entries).
- Synthetic root `/Hither/` via `/etc/synthetic.conf`; materialized without reboot via `apfs.util -t`.
- Server side: `server/hither-sync.sh` (renamed from `auto-smb-sync.sh` in admin-technical), runs under xyOps on Umbridge; enumerates DSM shares and pushes per-Mac maps via the wrapper.
- Documentation: README, docs/architecture.md, docs/design-decisions.md, docs/glossary.md.
- Install: `lash install` (dev-clone path).

### Scope (v1)
- Single subscriber: SusanBones.
- Single source: Umbridge (Synology DSM).
- PRIVATE repo only.

### Deferred to v2
- Hedwig + other static-peer Macs (need different "static-curated map" mode).
- Other subscriber Macs.
- Public release + sanitization.
- Homebrew tap formula.
- `hither subscribe` / `hither add-peer` CLI subcommands.

### Forked from
- `admin-technical/setup/synology/xyops/jobs/auto-smb-sync*` (fresh-copy import; no admin-technical git history preserved).
- `admin-technical/setup/macos/autofs-umbridge/setup-autofs-umbridge.sh` (logic only; runtime data heredoc deliberately not copied).
