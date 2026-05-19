# Changelog

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
