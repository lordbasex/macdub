// Test runner executable: `swift run macdub-tests` (or `make test`).
//
// Why an executable instead of a `.testTarget`: `swift test` needs Xcode's `xctest` runner to
// load test bundles on macOS, which the Command Line Tools do not ship. Swift Testing exposes
// the same entry point SwiftPM would use, so we call it ourselves.
import Foundation
import Testing

exit(await __swiftPMEntryPoint() as CInt)
