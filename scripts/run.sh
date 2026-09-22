#!/usr/bin/env bash
# Build (native arch only, for speed) and launch MacDub.
# Pass --universal to build both slices, or any build-app.sh env var (CONFIG, CODESIGN_IDENTITY…).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ "${1:-}" == "--universal" ]]; then
  export ARCHS="x86_64 arm64"
else
  export ARCHS="${ARCHS:-$(uname -m)}"
fi

"$ROOT/scripts/build-app.sh"
echo "▶ Launching"
open -n "$ROOT/build/MacDub.app"
