#!/usr/bin/env bash
# Resets the TCC (privacy) grants for MacDub so macOS prompts again.
#
# Why you might need this: an ad-hoc signed app gets a new code identity on every build, so
# macOS may silently stop honouring the Screen Recording grant after a rebuild. Either run
# this and re-approve, or sign with a stable identity (see README › Development signing).
set -euo pipefail
BUNDLE_ID="${BUNDLE_ID:-com.lordbasex.MacDub}"
for service in ScreenCapture SpeechRecognition; do
  echo "▶ tccutil reset $service $BUNDLE_ID"
  tccutil reset "$service" "$BUNDLE_ID" || true
done
