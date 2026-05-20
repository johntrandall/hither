# Glossary

Terms used in Hither documentation that aren't broadly known.

## macOS subsystems

| Term | Meaning |
|---|---|
| **autofs** | macOS's lazy-mount subsystem. Configured via `/etc/auto_master` (top-level map) and per-mountpoint maps like `/etc/auto_smb`. Mounts a filesystem on first access, unmounts after idle timeout. |
| **automount** | The CLI tool that flushes autofs's configuration cache: `automount -cv` re-reads `auto_master` and child maps. |
| **automountd** | The system daemon that performs the actual mount when a process touches a path under an autofs-managed root. |
| **synthetic.conf** | Apple-provided mechanism (`/etc/synthetic.conf`) for adding synthetic root-level paths that survive OS updates. Originally added to support the read-only system volume (Catalina+). Each line creates either an empty directory or a symlink at the root. |
| **apfs.util -t** | Materializes a synthetic.conf change without a reboot. Not Apple-documented for this use; established by the Nix installer and widely copied. |
| **Sealed System Volume (SSV)** | The read-only system volume macOS Sequoia (and earlier, since Big Sur) mounts at `/`. Writable system state is kept on the separate `/System/Volumes/Data/` volume, joined back into the namespace via firmlinks. |
| **Keychain (Internet password)** | macOS's credential store. `security add-internet-password` / `find-internet-password` are the CLI accessors. The same entries Finder Cmd-K populates for SMB/AFP mounts. |
| **LaunchDaemon** | A launchd-managed service that runs as root, in the system context. Plist lives at `/Library/LaunchDaemons/`. No GUI session, no per-user environment. |
| **LaunchAgent** | A launchd-managed service that runs as a user, in a GUI security session. Plist lives at `~/Library/LaunchAgents/`. Has Keychain access. |
| **WatchPaths** | A launchd plist key that fires the service whenever a listed file changes. Used by the Hither bootstrap daemon to re-apply state when macOS updates revert it. |

## SMB / DSM

| Term | Meaning |
|---|---|
| **SMB** | Server Message Block — the file-sharing protocol macOS uses to mount Synology and other network shares. |
| **DSM** | DiskStation Manager — Synology's NAS operating system. Exposes a Web API at `:5000` (HTTP) / `:5001` (HTTPS) that Hither uses to enumerate the user's visible shares. |
| **indirect map** | An autofs map type where the keys are share names rather than full paths. `/Hither/<nas>` is an indirect-map mountpoint; `/Hither/<nas>/<share>` triggers a lazy mount of `<share>` on first access. |
