import Foundation
import os

/// One logger per pipeline stage. View with `log stream --predicate 'subsystem == "com.lordbasex.MacDub"'`
/// or in Console.app.
enum Log {
    static let subsystem = Bundle.main.bundleIdentifier ?? "com.lordbasex.MacDub"
    static let app = Logger(subsystem: subsystem, category: "app")
    static let capture = Logger(subsystem: subsystem, category: "capture")
    static let speech = Logger(subsystem: subsystem, category: "speech")
    static let translation = Logger(subsystem: subsystem, category: "translation")
    static let voice = Logger(subsystem: subsystem, category: "voice")
}
