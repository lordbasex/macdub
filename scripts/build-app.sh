#!/usr/bin/env bash
# Builds MacDub with SwiftPM and assembles build/MacDub.app — no Xcode required,
# only the Command Line Tools.
#
# Environment overrides:
#   CONFIG=debug|release        (default: release)
#   ARCHS="x86_64 arm64"        (default: both → universal binary; use one to build faster)
#   CODESIGN_IDENTITY="..."     (default: "-" = ad-hoc. Use a self-signed "MacDub Dev" cert
#                                to keep Screen Recording permission across rebuilds, or a
#                                "Developer ID Application: ..." identity for distribution)
#   BUNDLE_ID=...               (default: com.lordbasex.MacDub)
#   VERSION=... BUILD_NUMBER=...
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="MacDub"

# On a Mac without the toolchain, run the setup (it launches xcode-select --install and waits).
if ! command -v swift >/dev/null 2>&1 || ! xcode-select -p >/dev/null 2>&1; then
  echo "▶ Swift toolchain not found — running scripts/setup.sh first"
  "$ROOT/scripts/setup.sh" --no-cert || exit 1
fi
CONFIG="${CONFIG:-release}"
ARCHS="${ARCHS:-x86_64 arm64}"
# Prefer the stable dev certificate (scripts/make-dev-cert.sh) when it exists, else ad-hoc.
if [[ -z "${CODESIGN_IDENTITY:-}" ]]; then
  if security find-identity -v -p codesigning 2>/dev/null | grep -q '"MacDub Dev"'; then
    CODESIGN_IDENTITY="MacDub Dev"
  else
    CODESIGN_IDENTITY="-"
  fi
fi
BUNDLE_ID="${BUNDLE_ID:-com.lordbasex.MacDub}"
VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/$APP_NAME.app"

# Passing several --arch flags at once makes SwiftPM delegate to xcbuild, which only ships
# with Xcode. Building one slice at a time and merging with lipo works with the CLT alone.
SLICES=()
MCP_SLICES=()
# Build-system flags (see scripts/swift-flags.sh): the classic build system, and the SDK's
# macro plugins. Newer toolchains default to the "Swift Build" backend, which does not hand the
# compiler the SDK plugin folder where SwiftUIMacros lives — every @State then fails with
# "plugin for module 'SwiftUIMacros' not found" (seen with the macOS 26 SDK on Apple Silicon).
# shellcheck source=swift-flags.sh
source "$ROOT/scripts/swift-flags.sh"

for a in $ARCHS; do
  echo "▶ swift build -c $CONFIG --arch $a ${SWIFT_BUILD_FLAGS[*]}"
  swift build -c "$CONFIG" --arch "$a" --package-path "$ROOT" --product "$APP_NAME" "${SWIFT_BUILD_FLAGS[@]}"
  swift build -c "$CONFIG" --arch "$a" --package-path "$ROOT" --product macdub-mcp "${SWIFT_BUILD_FLAGS[@]}"
  BIN="$(swift build -c "$CONFIG" --arch "$a" --package-path "$ROOT" --show-bin-path "${SWIFT_BUILD_FLAGS[@]}")"
  SLICES+=("$BIN/$APP_NAME")
  MCP_SLICES+=("$BIN/macdub-mcp")
done

echo "▶ Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"
if [[ ${#SLICES[@]} -gt 1 ]]; then
  lipo -create "${SLICES[@]}" -output "$APP/Contents/MacOS/$APP_NAME"
  lipo -create "${MCP_SLICES[@]}" -output "$APP/Contents/Helpers/macdub-mcp"
else
  cp "${SLICES[0]}" "$APP/Contents/MacOS/$APP_NAME"
  cp "${MCP_SLICES[0]}" "$APP/Contents/Helpers/macdub-mcp"
fi
sed -e "s/\${BUNDLE_ID}/$BUNDLE_ID/g" \
    -e "s/\${VERSION}/$VERSION/g" \
    -e "s/\${BUILD_NUMBER}/$BUILD_NUMBER/g" \
    "$ROOT/Packaging/Info.plist" > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Localizations: SwiftPM emits them inside MacDub_MacDub.bundle; placing the .lproj folders
# directly in Contents/Resources lets Bundle.main (and plain SwiftUI Text) find them.
LAST_ARCH="${ARCHS##* }"
RES_BUNDLE="$(swift build -c "$CONFIG" --arch "$LAST_ARCH" --package-path "$ROOT" --show-bin-path "${SWIFT_BUILD_FLAGS[@]}")/MacDub_MacDub.bundle"
if [[ -d "$RES_BUNDLE" ]]; then
  find "$RES_BUNDLE" -name '*.lproj' -type d -maxdepth 3 -exec cp -R {} "$APP/Contents/Resources/" \;
fi
if [[ -f "$ROOT/Packaging/AppIcon.icns" ]]; then
  cp "$ROOT/Packaging/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

echo "▶ codesign (identity: $CODESIGN_IDENTITY)"
SIGN_FLAGS=(--force --sign "$CODESIGN_IDENTITY" --entitlements "$ROOT/Packaging/MacDub.entitlements" --options runtime)
# Only real Developer ID identities get a trusted timestamp (needs network + Apple's TSA).
if [[ "$CODESIGN_IDENTITY" == Developer\ ID* ]]; then SIGN_FLAGS+=(--timestamp); fi
# Nested helper first, then the bundle (which seals the helper's signature).
codesign "${SIGN_FLAGS[@]}" "$APP/Contents/Helpers/macdub-mcp"
codesign "${SIGN_FLAGS[@]}" "$APP"
codesign --verify --deep --strict "$APP"

echo
echo "✔ Built $APP"
lipo -info "$APP/Contents/MacOS/$APP_NAME"
