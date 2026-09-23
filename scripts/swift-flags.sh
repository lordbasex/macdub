#!/usr/bin/env bash
# Sourced by the build scripts and the Makefile: extra `swift build` flags that keep the build
# working across toolchains. Sets the SWIFT_BUILD_FLAGS array.
#
# 1. `--build-system native` when the toolchain knows the flag. Newer SwiftPMs default to the
#    "Swift Build" backend, which resolves macro plugins explicitly and misses the SDK's own
#    (SwiftUIMacros in the macOS 26 SDK), so every @State fails to compile.
# 2. `-plugin-path <SDK>/usr/lib/swift/host/plugins` when that folder exists, so the SDK's macro
#    implementations are found whatever the build system does.

SWIFT_BUILD_FLAGS=()
if swift build --help 2>/dev/null | grep -q -- '--build-system'; then
  SWIFT_BUILD_FLAGS+=(--build-system native)
fi
SDK_PLUGINS="$(xcrun --show-sdk-path 2>/dev/null)/usr/lib/swift/host/plugins"
if [[ -d "$SDK_PLUGINS" ]]; then
  SWIFT_BUILD_FLAGS+=(-Xswiftc -plugin-path -Xswiftc "$SDK_PLUGINS")
fi
export SWIFT_BUILD_FLAGS
