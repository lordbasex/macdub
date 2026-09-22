import AppKit

/// AppKit glue: owns the menu bar item and keeps the app alive in the menu bar when the
/// main window is closed.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBar: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusBar = StatusBarController(state: AppState.shared)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppState.shared.shutdown()
    }

    /// Dock icon click with no window open → bring the main window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { AppState.shared.showMainWindow() }
        return true
    }

    /// Coming back from System Settings after downloading voices: refresh the list.
    func applicationDidBecomeActive(_ notification: Notification) {
        AppState.shared.reloadVoices()
    }
}
