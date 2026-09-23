# MacDub — build without Xcode (Command Line Tools + SwiftPM). No third-party dependencies:
# nothing is downloaded; the only requirement is macOS 15+ with Swift 6 Command Line Tools.
#
#   make setup      check the toolchain on a fresh Mac and create the dev signing certificate
#   make            build a universal (x86_64 + arm64) release .app into build/
#   make run        build for this Mac's architecture only and launch it
#   make dmg        universal build packed as a drag-to-Applications disk image (build/MacDub-<version>.dmg)
#   make debug      debug build for this architecture
#   make check      type-check quickly (swift build, no bundle)
#   make clean
#
# Variables you can override: CODESIGN_IDENTITY, BUNDLE_ID, VERSION, ARCHS, CONFIG.

.PHONY: all setup universal run debug check test clean reset-permissions notarize release zip dmg dmg-native

setup:
	./scripts/setup.sh

# Unit tests (Swift Testing). An executable runner instead of `swift test`, because the
# Command Line Tools lack Xcode's xctest loader — see Tests/Runner/main.swift.
test:
	swift run macdub-tests

all: universal

universal:
	./scripts/build-app.sh

run:
	./scripts/run.sh

debug:
	CONFIG=debug ./scripts/run.sh

check:
	swift build

clean:
	rm -rf build .build

reset-permissions:
	./scripts/reset-permissions.sh

notarize:
	./scripts/sign-and-notarize.sh

# VERSION=0.2.0 make release  → universal zip + sha256 + cask update (+ GitHub release with gh)
release:
	./scripts/release.sh

# Universal zip for testing on another Mac (e.g. Apple Silicon), no release bookkeeping.
# Ad-hoc signed on purpose: the dev certificate is not trusted on other machines anyway.
zip:
	CODESIGN_IDENTITY=- ./scripts/build-app.sh
	rm -f build/MacDub-universal.zip
	ditto -c -k --keepParent build/MacDub.app build/MacDub-universal.zip
	shasum -a 256 build/MacDub-universal.zip
	@echo "✔ build/MacDub-universal.zip — on the other Mac: unzip, right-click › Open the first time"

# Installer disk image: MacDub.app + Applications shortcut, MacDub icon on the volume, background
# with an arrow. `dmg` packs a universal build; `dmg-native` reuses the current build/MacDub.app
# (e.g. right after make run) for a quick local check.
dmg:
	./scripts/build-app.sh
	./scripts/make-dmg.sh

dmg-native:
	./scripts/make-dmg.sh
