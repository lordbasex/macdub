#!/usr/bin/env bash
# Cuts a release: universal build, (optional) Developer ID signing + notarization, zip,
# SHA-256, Homebrew cask update, and — when `gh` is available — a GitHub release.
#
# Usage:
#   VERSION=0.2.0 ./scripts/release.sh                 # ad-hoc/dev-signed zip, no notarization
#   VERSION=0.2.0 CODESIGN_IDENTITY="Developer ID Application: …" NOTARY_PROFILE=MacDub-Notary ./scripts/release.sh
#
# Outputs: build/MacDub-<version>.zip (+ .sha256), build/MacDub-<version>.dmg (+ .sha256), Casks/macdub.rb updated.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${VERSION:?Set VERSION, e.g. VERSION=0.2.0}"
REPO="${REPO:-lordbasex/macdub}"
export VERSION ARCHS="x86_64 arm64"

if [[ -n "${NOTARY_PROFILE:-}" && -n "${CODESIGN_IDENTITY:-}" ]]; then
  "$ROOT/scripts/sign-and-notarize.sh"
  mv "$ROOT/build/MacDub.zip" "$ROOT/build/MacDub-$VERSION.zip"
else
  echo "▶ No NOTARY_PROFILE/CODESIGN_IDENTITY: building an unnotarized universal zip"
  "$ROOT/scripts/build-app.sh"
  rm -f "$ROOT/build/MacDub-$VERSION.zip"
  ditto -c -k --keepParent "$ROOT/build/MacDub.app" "$ROOT/build/MacDub-$VERSION.zip"
fi

ZIP="$ROOT/build/MacDub-$VERSION.zip"
SHA="$(shasum -a 256 "$ZIP" | awk '{print $1}')"
echo "$SHA  $(basename "$ZIP")" > "$ZIP.sha256"
echo "▶ $(basename "$ZIP") sha256 $SHA"

# Drag-to-install image next to the zip (the cask keeps using the zip).
"$ROOT/scripts/make-dmg.sh"
DMG="$ROOT/build/MacDub-$VERSION.dmg"

echo "▶ Updating Casks/macdub.rb"
sed -i '' -e "s/^  version \".*\"/  version \"$VERSION\"/" -e "s/^  sha256 \".*\"/  sha256 \"$SHA\"/" "$ROOT/Casks/macdub.rb"

# `gh` may live in a PATH only the login shell knows (Homebrew, ~/.local/bin).
GH="$(command -v gh || /bin/zsh -lc 'command -v gh' 2>/dev/null || true)"
if [[ -n "$GH" && "${GITHUB_RELEASE:-1}" == "1" ]]; then
  gh() { "$GH" "$@"; }
  echo "▶ Creating GitHub release v$VERSION on $REPO"
  gh release create "v$VERSION" "$ZIP" "$ZIP.sha256" "$DMG" "$DMG.sha256" --repo "$REPO" --title "MacDub $VERSION" --generate-notes \
    || echo "  (gh release failed or already exists — upload $ZIP manually)"
else
  echo "▶ GitHub release skipped ($([[ -n "$GH" ]] && echo 'GITHUB_RELEASE=0' || echo 'gh not installed')): upload $ZIP to https://github.com/$REPO/releases/new (tag v$VERSION)"
fi
echo "✔ Release artifacts in build/"
