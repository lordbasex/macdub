// swift-tools-version:6.0
import PackageDescription
import Foundation

// Without Xcode, Swift Testing lives in the Command Line Tools' private Frameworks folder and
// its Foundation cross-import overlay is not shipped; point the test runner there and turn the
// overlays off for it only (the app target needs the Translation+SwiftUI overlay).
let cltFrameworks = "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
let usesCLTTesting = !FileManager.default.fileExists(atPath: "/Applications/Xcode.app")
    && FileManager.default.fileExists(atPath: "\(cltFrameworks)/Testing.framework")
let testSwiftFlags: [SwiftSetting] = usesCLTTesting
    ? [.unsafeFlags(["-F", cltFrameworks, "-Xfrontend", "-disable-cross-import-overlays"])]
    : []
let testLinkerFlags: [LinkerSetting] = usesCLTTesting
    ? [.unsafeFlags(["-F", cltFrameworks, "-Xlinker", "-rpath", "-Xlinker", cltFrameworks])]
    : []

let package = Package(
    name: "MacDub",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v15)
    ],
    targets: [
        // Pure, framework-free logic (sentence segmentation, export, rate policy) — unit-tested.
        .target(
            name: "MacDubCore",
            path: "Sources/MacDubCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "MacDub",
            dependencies: ["MacDubCore"],
            path: "Sources/MacDub",
            resources: [
                // Localizable.strings per language. scripts/build-app.sh copies the .lproj
                // folders into the app bundle so `Bundle.main` finds them without `.module`.
                .process("Resources")
            ],
            swiftSettings: [
                // Apple's delegate-based frameworks (ScreenCaptureKit, Speech, AVFAudio)
                // are much easier to bridge in Swift 5 language mode. Concurrency is
                // still used everywhere; we just don't opt into strict checking yet.
                .swiftLanguageMode(.v5)
            ]
        ),
        // MCP server (stdio) bundled into MacDub.app/Contents/Helpers; see Sources/MacDubMCP.
        .executableTarget(
            name: "macdub-mcp",
            dependencies: ["MacDubCore"],
            path: "Sources/MacDubMCP",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Tests as an executable (`swift run macdub-tests`): `swift test` needs Xcode's xctest
        // runner, which the Command Line Tools don't include. See Tests/Runner/main.swift.
        .executableTarget(
            name: "macdub-tests",
            dependencies: ["MacDubCore"],
            path: "Tests/Runner",
            swiftSettings: [.swiftLanguageMode(.v5)] + testSwiftFlags,
            linkerSettings: testLinkerFlags
        )
    ]
)
