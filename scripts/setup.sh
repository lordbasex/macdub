#!/usr/bin/env bash
# One-time check for a fresh Mac: verifies the toolchain, offers to install the Command Line
# Tools, and creates the stable dev signing certificate. MacDub has no third-party
# dependencies — nothing else is downloaded.
#
#   make setup
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ok()   { printf '  ✔ %s\n' "$*"; }
warn() { printf '  ⚠ %s\n' "$*"; }
bad()  { printf '  ✖ %s\n' "$*"; FAILED=1; }
FAILED=0

echo "▶ macOS"
OS="$(sw_vers -productVersion)"
if [[ "${OS%%.*}" -ge 15 ]]; then ok "macOS $OS ($(uname -m))"; else bad "macOS $OS — MacDub needs 15 Sequoia or later"; fi

echo "▶ Command Line Tools / Swift"
# Installs the Command Line Tools when missing: `xcode-select --install` opens Apple's dialog
# and returns at once, so we wait for the install to land before going on.
install_clt_if_needed() {
  if xcode-select -p >/dev/null 2>&1 && command -v swift >/dev/null 2>&1; then return 0; fi
  echo "  Command Line Tools not found — launching the installer (Apple's dialog, ~2 GB download)."
  xcode-select --install 2>/dev/null || true
  echo "  Accept the dialog and wait; this script continues automatically when the install finishes…"
  local waited=0
  until xcode-select -p >/dev/null 2>&1 && command -v swift >/dev/null 2>&1; do
    sleep 10
    waited=$((waited + 10))
    if (( waited % 60 == 0 )); then printf '  … still waiting (%d min)\n' $((waited / 60)); fi
    if (( waited >= 3600 )); then bad "gave up after 60 min — install the Command Line Tools and run make setup again"; return 1; fi
  done
  ok "Command Line Tools installed"
}
install_clt_if_needed
if xcode-select -p >/dev/null 2>&1; then
  ok "developer directory: $(xcode-select -p)"
fi
if command -v swift >/dev/null 2>&1; then
  SWIFT_VER="$(swift --version 2>/dev/null | grep -oE 'Swift version [0-9]+\.[0-9]+' | head -1 | awk '{print $3}')"
  if [[ -n "$SWIFT_VER" && "${SWIFT_VER%%.*}" -ge 6 ]]; then
    ok "Swift $SWIFT_VER"
  else
    bad "Swift ${SWIFT_VER:-unknown} — need 6.0 or newer. Update the Command Line Tools (Software Update) or install Xcode 16+"
  fi
else
  bad "swift not found in PATH"
fi

echo "▶ SDK frameworks"
SDK="$(xcrun --show-sdk-path 2>/dev/null || true)"
if [[ -n "$SDK" ]]; then
  MISSING=""
  for f in ScreenCaptureKit Speech Translation AVFAudio Network ServiceManagement; do
    [[ -d "$SDK/System/Library/Frameworks/$f.framework" ]] || MISSING="$MISSING $f"
  done
  if [[ -z "$MISSING" ]]; then ok "SDK $(basename "$SDK") has every framework MacDub uses"; else bad "SDK is missing:$MISSING (update the Command Line Tools)"; fi
  if [[ -d "$SDK/System/Library/Frameworks/FoundationModels.framework" ]]; then
    ok "macOS 26 SDK present: SpeechAnalyzer / Apple Intelligence paths will compile"
  else
    warn "SDK older than macOS 26 (Swift < 6.2): SpeechAnalyzer and Apple Intelligence are compiled out; the app still builds and runs with SFSpeechRecognizer"
  fi
fi

echo "▶ Optional tools"
if [[ -d /Applications/Xcode.app ]]; then ok "Xcode found (swift test works too)"; else ok "no Xcode — fine, tests run with: make test"; fi
command -v gh >/dev/null 2>&1 && ok "gh (GitHub CLI) for make release" || warn "gh not installed — make release will skip the GitHub upload"
command -v claude >/dev/null 2>&1 && ok "Claude Code CLI ($(claude --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1))" || warn "Claude Code CLI not found (only needed for in-app summaries / MCP registration)"

echo "▶ Signing certificate"
if security find-identity -v -p codesigning 2>/dev/null | grep -q '"MacDub Dev"'; then
  ok "\"MacDub Dev\" certificate present"
else
  if [[ "${1:-}" == "--no-cert" ]]; then
    warn "no \"MacDub Dev\" certificate — builds will be ad-hoc signed and macOS will re-ask for Screen Recording after every rebuild. Create it with: ./scripts/make-dev-cert.sh"
  else
    echo "  creating the \"MacDub Dev\" certificate (macOS may ask for your password once)…"
    if "$ROOT/scripts/make-dev-cert.sh" >/dev/null 2>&1; then ok "certificate created"; else warn "could not create it (run ./scripts/make-dev-cert.sh by hand); builds fall back to ad-hoc signing"; fi
  fi
fi

echo
if [[ "$FAILED" -eq 0 ]]; then
  echo "✔ Ready. Next:  make run"
else
  echo "✖ Fix the items marked ✖ above, then run make setup again."
  exit 1
fi
