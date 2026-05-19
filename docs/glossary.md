# Glossary

Terms used in Hither documentation that a non-John reader would not know.

## John-specific infrastructure

| Term | Meaning |
|---|---|
| **xyOps** | John's centralized job scheduler. Conductor component on Umbridge, xysat satellites on each managed Mac. Conceptually like cron, but distributed — with Secrets management, event lifecycle, and observability built in. Replaces ad-hoc launchd jobs scattered across the fleet. |
| **xysat** | The per-Mac xyOps satellite process. Runs as `infra-agent`. Receives job dispatch events from Conductor and executes the local handler. |
| **infra-agent** | Claude's service-account identity on all of John's shared infrastructure — Macs, Synology NAS devices, HA Yellow, Docker hosts, anything John has delegated. Distinct from John's personal accounts (`johnrandall` on Macs, `johnadmin` on Synology). |
| **Umbridge** | John's Synology DiskStation (RS1221+ in the rack at 179 Summit). Synology hostnames follow the Harry Potter naming theme. Holds shared filesystems, Docker stacks, and the xyOps Conductor. |
| **SusanBones** | John's primary Mac — a Mac Studio at 179 Summit. Also Harry Potter themed. |
| **DSM** | DiskStation Manager. The Synology NAS operating system. |
| **lash** | John's lightweight symlink-install tool for CLI development. Reads a `lash.json` manifest and creates symlinks from the dev clone into `~/.local/bin/` (and similar locations). The lightweight alternative to `brew install` for tools that don't have a tap yet. |

## macOS subsystems

| Term | Meaning |
|---|---|
| **autofs** | macOS's lazy-mount subsystem. Configured via `/etc/auto_master` (top-level map) and per-mountpoint maps like `/etc/auto_smb`. Mounts a filesystem on first access, unmounts after idle timeout. |
| **automount** | The CLI tool that flushes autofs's configuration cache: `automount -cv` re-reads `auto_master` and child maps. |
| **automountd** | The system daemon that performs the actual mount when a process touches a path under an autofs-managed root. |
| **synthetic.conf** | Apple-provided mechanism (`/etc/synthetic.conf`) for adding synthetic root-level paths that survive OS updates. Originally added to support read-only system volume (Catalina+). Each line creates either an empty directory or a symlink at the root. |
| **apfs.util -t** | Materializes a synthetic.conf change without a reboot. Not Apple-documented for this use; established by the Nix installer and widely copied. |
