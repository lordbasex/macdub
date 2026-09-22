#!/usr/bin/env bash
# Signs build/MacDub.app with a Developer ID identity, notarizes it with Apple and
# staples the ticket, then zips it for distribution.
#
# Prerequisites (one time):
#   1. Apple Developer Program membership.
#   2. "Developer ID Application: Your Name (TEAMID)" certificate in your login keychain.
#   3. An app-specific password stored for notarytool:
#        xcrun notarytool store-credentials "MacDub-Notary" \
#          --apple-id you@example.com --team-id TEAMID --password <app-specific-password>
#
# Usage:
#   CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
#   NOTARY_PROFILE="MacDub-Notary" ./scripts/sign-and-notarize.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/MacDub.app"
ZIP="$ROOT/build/MacDub.zip"
: "${CODESIGN_IDENTITY:?Set CODESIGN_IDENTITY to your 'Developer ID Application: ...' identity}"
: "${NOTARY_PROFILE:?Set NOTARY_PROFILE to the notarytool keychain profile name}"

export CODESIGN_IDENTITY
"$ROOT/scripts/build-app.sh"

echo "▶ Zipping for notarization"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "▶ Submitting to Apple notary service (this can take a few minutes)"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait

echo "▶ Stapling ticket"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=2 "$APP"

echo "▶ Re-zipping stapled app"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "✔ Ready to share: $ZIP"
