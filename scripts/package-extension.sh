#!/usr/bin/env bash
# Packs the Chrome extension (extensions/meet-chat) as the .zip the Chrome Web Store asks for:
# build/MacDub-Meet-extension-<version>.zip, manifest.json at the root.
#
#   scripts/package-extension.sh
#
# Upload it in the Chrome Web Store Developer Dashboard (docs/chrome-extension/STORE-LISTING.md
# has the listing texts, PRIVACY.md the privacy policy). Once it is published, put its id in
# ChromeExtension.webStoreID so Settings › Extensions installs it from the store.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/extensions/meet-chat"
VERSION="$(python3 -c "import json; print(json.load(open('$SRC/manifest.json'))['version'])")"
OUT="$ROOT/build/MacDub-Meet-extension-$VERSION.zip"
mkdir -p "$ROOT/build"
rm -f "$OUT"
(cd "$SRC" && zip -qr -X "$OUT" . -x '.*' -x '*/.*')
echo "✔ $OUT"
unzip -l "$OUT" | tail -n +4 | sed '$d' | sed '$d'
