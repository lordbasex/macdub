#!/usr/bin/env bash
# Sourced by the build scripts and the Makefile: extra `swift build` flags that keep the build
# working across toolchains. Sets the SWIFT_BUILD_FLAGS array.
#
# 1. `--build-system native` when the toolchain knows the flag. Newer SwiftPMs default to the
#    "Swift Build" backend, which resolves macro plugins explicitly and misses the SDK's own
#    (SwiftUIMacros in the macOS 26 SDK), so every @State fails to compile.
# 2. `-plugin-path <SDK>/usr/lib/swift/host/plugins` when that folder exists, so the SDK's macro
#    implementations are found whatever the build system does.
# 3. If the SDK declares SwiftUI's `@State` as a macro but no SwiftUIMacros plugin is installed
#    (Command Line Tools with the macOS 27 SDK ship the macro but not its plugin), fall back to the
#    newest installed SDK that still has the classic property wrapper, via SDKROOT.

swiftui_needs_macro_plugin() {
  local sdk="$1" iface
  iface="$sdk/System/Library/Frameworks/SwiftUICore.framework/Modules/SwiftUICore.swiftmodule/arm64e-apple-macos.swiftinterface"
  [[ -f "$iface" ]] && grep -q 'public macro State()' "$iface"
}
swiftui_macro_plugin_present() {
  local sdk="$1" dev
  dev="$(xcode-select -p 2>/dev/null)"
  compgen -G "$sdk/usr/lib/swift/host/plugins/*SwiftUIMacros*" >/dev/null ||
    compgen -G "$dev/usr/lib/swift/host/plugins/*SwiftUIMacros*" >/dev/null ||
    compgen -G "$dev/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins/*SwiftUIMacros*" >/dev/null ||
    compgen -G "$dev/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins/*SwiftUIMacros*" >/dev/null
}
if [[ -z "${SDKROOT:-}" ]]; then
  SDK_PATH="$(xcrun --show-sdk-path 2>/dev/null)"
  if [[ -n "$SDK_PATH" ]] && swiftui_needs_macro_plugin "$SDK_PATH" && ! swiftui_macro_plugin_present "$SDK_PATH"; then
    for candidate in $(ls -d "$(dirname "$SDK_PATH")"/MacOSX[0-9]*.sdk 2>/dev/null | sort -rV); do
      [[ -L "$candidate" ]] && continue
      if ! swiftui_needs_macro_plugin "$candidate"; then
        echo "▶ $(basename "$(readlink -f "$SDK_PATH")") needs the SwiftUIMacros plugin, which is not installed — using $(basename "$candidate")" >&2
        export SDKROOT="$candidate"
        break
      fi
    done
  fi
fi

SWIFT_BUILD_FLAGS=()
if swift build --help 2>/dev/null | grep -q -- '--build-system'; then
  SWIFT_BUILD_FLAGS+=(--build-system native)
fi
SDK_PLUGINS="${SDKROOT:-$(xcrun --show-sdk-path 2>/dev/null)}/usr/lib/swift/host/plugins"
if [[ -d "$SDK_PLUGINS" ]]; then
  SWIFT_BUILD_FLAGS+=(-Xswiftc -plugin-path -Xswiftc "$SDK_PLUGINS")
fi
export SWIFT_BUILD_FLAGS
