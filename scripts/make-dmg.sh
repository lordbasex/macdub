#!/usr/bin/env bash
# Packs build/MacDub.app into a drag-to-install disk image: build/MacDub-<version>.dmg.
#
# The mounted volume shows the MacDub icon, a background with an arrow, MacDub.app on the
# left and an Applications shortcut on the right. Needs only macOS tools (hdiutil, SetFile,
# osascript). The Finder layout step asks once for permission to automate Finder; if it is
# denied the image is still produced, just without the window layout.
#
# Usage: ./scripts/make-dmg.sh              (after ./scripts/build-app.sh or make run)
#        VERSION=0.2.0 ./scripts/make-dmg.sh
#        CODESIGN_IDENTITY="Developer ID Application: …" ./scripts/make-dmg.sh   (signs the .dmg)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/build"
APP="$BUILD/MacDub.app"
VERSION="${VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo 0.1.0)}"
VOLNAME="MacDub"
DMG="$BUILD/MacDub-$VERSION.dmg"
RW="$BUILD/MacDub-rw.dmg"
STAGE="$BUILD/dmg-root"
BACKGROUND="$ROOT/Packaging/dmg-background.tiff"
ICON="$ROOT/Packaging/AppIcon.icns"

[[ -d "$APP" ]] || { echo "✘ $APP not found — run make run (or make) first" >&2; exit 1; }
[[ -f "$BACKGROUND" ]] || swift "$ROOT/scripts/make-dmg-background.swift"

# A stale mount with the same name would confuse the Finder step.
if [[ -d "/Volumes/$VOLNAME" ]]; then hdiutil detach "/Volumes/$VOLNAME" -quiet || true; fi

echo "▶ Staging"
rm -rf "$STAGE" "$RW" "$DMG"
mkdir -p "$STAGE/.background"
ditto "$APP" "$STAGE/MacDub.app"
ln -s /Applications "$STAGE/Applications"
cp "$BACKGROUND" "$STAGE/.background/background.tiff"

echo "▶ Creating writable image"
hdiutil create -srcfolder "$STAGE" -volname "$VOLNAME" -fs HFS+ -fsargs "-c c=64,a=16,e=16" \
  -format UDRW -size 400m "$RW" -quiet
MOUNT_OUT="$(hdiutil attach -readwrite -noverify -noautoopen "$RW")"
DEV="$(echo "$MOUNT_OUT" | grep -E '^/dev/' | head -1 | awk '{print $1}')"
VOL="/Volumes/$VOLNAME"

echo "▶ Finder layout"
if ! osascript <<APPLESCRIPT
tell application "Finder"
  tell disk "$VOLNAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 860, 520}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 128
    set text size of opts to 13
    set background picture of opts to file ".background:background.tiff"
    set position of item "MacDub.app" of container window to {165, 190}
    set position of item "Applications" of container window to {495, 190}
    close
    open
    update without registering applications
    delay 1
    close
  end tell
end tell
APPLESCRIPT
then
  echo "  (Finder layout skipped — allow Terminal to control Finder in System Settings › Privacy & Security › Automation and rerun)"
fi

# Custom volume icon — LAST, after every Finder call: Finder's `update` on the disk deletes
# .VolumeIcon.icns and clears the flag (verified on macOS 15), and `hdiutil create -srcfolder`
# does not copy the file from the staging folder either. The C flag tells Finder to use it.
cp "$ICON" "$VOL/.VolumeIcon.icns"
SetFile -a C "$VOL"
SetFile -a V "$VOL/.background" 2>/dev/null || true
sync
sleep 1
hdiutil detach "$DEV" -quiet

echo "▶ Compressing"
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$DMG" -quiet
rm -f "$RW"
rm -rf "$STAGE"

if [[ -n "${CODESIGN_IDENTITY:-}" && "$CODESIGN_IDENTITY" != "-" ]]; then
  echo "▶ Signing image"
  codesign --sign "$CODESIGN_IDENTITY" --timestamp "$DMG"
fi

shasum -a 256 "$DMG" | tee "$DMG.sha256"
echo "✔ $DMG"
