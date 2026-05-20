# typed: false
# frozen_string_literal: true

# Hither — lazy mounter for personal Mac SMB fleets.
#
# This formula is the canonical source; it is intended to be mirrored
# into a separate `homebrew-hither` tap repo at install time. See
# docs/HOMEBREW.md for the tap-setup procedure.
class Hither < Formula
  desc "Lazy mounter for personal Mac SMB fleets — autofs + DSM + Keychain"
  homepage "https://github.com/johntrandall/hither"
  url "https://github.com/johntrandall/hither/archive/refs/tags/v0.4.0.tar.gz"
  sha256 "PLACEHOLDER_FILLED_AT_RELEASE_TIME"
  license "MIT"
  version "0.4.0"

  depends_on :macos
  depends_on macos: :sequoia # 15.0+; symlink-form synthetic.conf is tested on 15.7.x
  depends_on "jq"            # ships with macOS 15.0+ but pin for safety

  def install
    bin.install "bin/hither"
    libexec.install Dir["libexec/*"]
    pkgshare.install "bootstrap", "launchd", "sbin", "sudoers", "scripts", "completions"

    # Bash and zsh completions go in the standard Homebrew locations so
    # they're discovered automatically by `brew shellenv`-configured shells.
    bash_completion.install "completions/hither.bash" => "hither"
    zsh_completion.install "completions/_hither" => "_hither"

    # Per-host runtime state (logs, etc.) is created on first run, not at
    # install time — but pre-create the etc tree so `hither bootstrap`
    # doesn't have to.
    (etc/"hither").mkpath
  end

  def caveats
    <<~EOS
      Hither installed. To complete setup:

        # Root phase (writes /etc/synthetic.conf, /etc/auto_master,
        # /usr/local/sbin/hither-write-map, /etc/sudoers.d/hither-write-map,
        # /usr/local/libexec/hither/, /Library/LaunchDaemons/...)
        sudo #{HOMEBREW_PREFIX}/bin/hither bootstrap

        # User phase (writes ~/Library/LaunchAgents/com.johnrandall.hither.sync.plist)
        hither bootstrap --user-only

        # Add your first NAS
        hither subscribe <nas> --user <dsm-user>

      A reboot is required after the first install for /Hither to
      materialize as a synthetic root.

      See `hither doctor` for a health snapshot, and the README at
      #{homepage} for the full lay of the land.

      The LaunchDaemon Label `com.johnrandall.hither.bootstrap` and the
      LaunchAgent Label `com.johnrandall.hither.sync` carry the original
      author's reverse-DNS prefix. These are historical and are not
      renamed across versions — they're baked into existing installs.
    EOS
  end

  test do
    # Smoke test — `hither version` must print "hither" with no root needed.
    assert_match "hither", shell_output("#{bin}/hither version")
  end
end
