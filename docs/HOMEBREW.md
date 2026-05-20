# Homebrew tap setup

The canonical Hither formula lives in this repo at `Formula/hither.rb`. To
make `brew install johntrandall/hither/hither` work, the formula has to be
mirrored into a tap repo at `github.com/johntrandall/homebrew-hither`.
This document describes how that tap is set up — the same procedure
applies for any fork that wants to publish its own tap.

## What "tap" means here

A Homebrew tap is just a GitHub repo named `homebrew-<tap>` whose top-level
`Formula/` directory holds one `.rb` file per formula. Once tapped, Homebrew
can install formulas from it by name:

```
brew tap johntrandall/hither       # one-time: registers the tap
brew install johntrandall/hither/hither
```

(or the shorthand `brew install johntrandall/hither/hither` which auto-taps.)

## Setting up the tap repo

One-time. Use `gh` (or the GitHub UI) — the repo just needs to exist with a
`Formula/` directory containing `hither.rb`.

```bash
# 1. Create the tap repo (public).
gh repo create johntrandall/homebrew-hither --public \
  --description "Homebrew tap for the Hither lazy mounter" \
  --license MIT

# 2. Clone, drop the formula in, commit.
git clone https://github.com/johntrandall/homebrew-hither.git
cd homebrew-hither
mkdir -p Formula
cp ../hither/Formula/hither.rb Formula/hither.rb

# 3. The formula's `sha256` is a placeholder. Compute the real value
#    against the release tarball:
TAG=v0.4.0
sha256=$(curl -sL "https://github.com/johntrandall/hither/archive/refs/tags/${TAG}.tar.gz" | shasum -a 256 | awk '{print $1}')
sed -i.bak "s|sha256 \"PLACEHOLDER_FILLED_AT_RELEASE_TIME\"|sha256 \"${sha256}\"|" Formula/hither.rb
rm Formula/hither.rb.bak

# 4. Commit & push.
git add Formula/hither.rb
git commit -m "hither v0.4.0"
git push origin main
```

## Per-release update

For every new Hither release tag, repeat steps 3-4 with the new tag's
sha256. The release process for Hither itself is:

1. Update `HITHER_VERSION` in `bin/hither` and `version "..."` in
   `Formula/hither.rb` to the new version.
2. Update `CHANGELOG.md`.
3. Commit + tag: `git tag vX.Y.Z && git push --tags`.
4. Update `johntrandall/homebrew-hither` as above.

A future automation could lift this with a GitHub Actions workflow in the
hither repo that, on tag push, opens a PR against the tap repo. Not done
yet — manual is fine while there's one publisher.

## Why a separate repo and not just `brew install --formula` from the
## hither repo itself?

You *can* `brew install` from a non-tap repo by URL — `brew install
./Formula/hither.rb` works inside a clone. But that's a development
affordance, not a distribution channel. The tap pattern is the canonical
way Homebrew users discover and update third-party formulas, and it's
what `brew update` polls.
