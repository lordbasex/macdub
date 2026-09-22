import Foundation
import ServiceManagement

/// Login item registration through `SMAppService` (macOS 13+). The app must live in a stable
/// location (e.g. /Applications) for macOS to launch it; from `build/` it still registers but
/// the entry breaks if the bundle is rebuilt elsewhere.
enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Returns an error message when macOS refused (e.g. blocked in Login Items settings).
    @discardableResult
    static func set(_ enabled: Bool) -> String? {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    static var requiresApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }
}
