import AppKit
import SwiftUI
import ScreenCaptureKit

/// PNGs of every screen, for checking layouts across languages, appearances and sizes without
/// Screen Recording permission (an app may always draw its own views into a bitmap).
///
/// Triggered with the `snapshotUI` command (see `MacDubCommand`), so it can run at any moment
/// of a session — idle, dubbing, with History open:
///
///     swift -e 'import Foundation; DistributedNotificationCenter.default().postNotificationName(
///       .init("com.lordbasex.MacDub.command"), object: nil,
///       userInfo: ["action": "snapshotUI", "path": "/tmp/ui", "label": "idle"], deliverImmediately: true)'
///
/// The main window is captured for real at its minimum and a large size, one PNG per section.
/// Settings tabs, the subtitle bar and the menu bar panel are laid out off screen, tall enough
/// to show all of their content. Writes `<label>.done` when finished.
@MainActor
enum UISnapshots {
    static func capture(to dir: URL, label: String, state: AppState) async {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let originalAppearance = NSApp.appearance
        let originalSection = state.section
        let originalFrame = state.mainWindow?.frame
        let language = Bundle.main.preferredLocalizations.first ?? "en"

        for (mode, appearance) in [("light", NSAppearance(named: .aqua)), ("dark", NSAppearance(named: .darkAqua))] {
            NSApp.appearance = appearance
            let prefix = "\(label)-\(language)-\(mode)"

            state.showMainWindow()
            try? await Task.sleep(for: .milliseconds(800))
            if let window = state.mainWindow {
                for size in [NSSize(width: 1040, height: 700), NSSize(width: 1440, height: 900)] {
                    window.setContentSize(size)
                    for section in AppSection.allCases {
                        state.section = section
                        try? await Task.sleep(for: .milliseconds(700))
                        await saveWindow(window, "\(prefix)-main-\(section.rawValue)-\(Int(size.width))x\(Int(size.height))", in: dir)
                    }
                    // History again with the newest session of each tab open (player, spectrum,
                    // transcript; a conversation for live translation).
                    let originalTab = UserDefaults.standard.string(forKey: "historyTab")
                    for (tab, name) in [(HistoryTab.dubbing, "session"), (HistoryTab.live, "live-session")] {
                        UserDefaults.standard.set(tab.rawValue, forKey: "historyTab")
                        state.section = .history
                        try? await Task.sleep(for: .milliseconds(500))
                        guard let newest = state.sessions.first(where: { $0.isLive == (tab == .live) })?.id else { continue }
                        state.historySelection = newest
                        try? await Task.sleep(for: .milliseconds(1500))
                        await saveWindow(window, "\(prefix)-main-history-\(name)-\(Int(size.width))x\(Int(size.height))", in: dir)
                        state.historySelection = nil
                    }
                    UserDefaults.standard.set(originalTab, forKey: "historyTab")
                }
            }

            for tab in SettingsView.snapshotTabs {
                await offscreen(tab.view.formStyle(.grouped), width: 640, appearance: appearance, state: state,
                                name: "\(prefix)-settings-\(tab.name)", in: dir)
            }
            await offscreen(MenuBarPanelView(dismiss: {}), width: nil, appearance: appearance, state: state,
                            name: "\(prefix)-menubar-panel", in: dir)
            await offscreen(FloatingSubtitlesView(), width: nil, appearance: appearance, state: state,
                            name: "\(prefix)-subtitle-bar", in: dir)
        }

        NSApp.appearance = originalAppearance
        state.section = originalSection
        if let originalFrame { state.mainWindow?.setFrame(originalFrame, display: true) }
        try? Data().write(to: dir.appendingPathComponent("\(label)-\(language).done"))
        Log.app.info("UI snapshots written to \(dir.path, privacy: .public)")
    }

    /// Lays `view` out in a borderless off-screen window at its natural height (capped) and saves it.
    private static func offscreen<V: View>(_ view: V, width: CGFloat?, appearance: NSAppearance?, state: AppState,
                                           name: String, in dir: URL) async {
        let host = NSHostingView(rootView: view.environmentObject(state))
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: width ?? 600, height: 400),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        // Transparent, like the floating bar and the popover really are: no box around them.
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView = host
        window.orderBack(nil)
        // Let onAppear tasks and async state (voices, storage size…) land before measuring.
        try? await Task.sleep(for: .milliseconds(600))
        let fitting = host.fittingSize
        let size = NSSize(width: width ?? max(fitting.width, 200), height: min(max(fitting.height, 120), 2400))
        window.setContentSize(size)
        host.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(300))
        save(host, name, in: dir)
        window.orderOut(nil)
        window.contentView = nil
    }

    /// The real pixels of one of our windows through ScreenCaptureKit (MacDub holds the Screen
    /// Recording grant anyway). `cacheDisplay` leaves scroll views black — the Subtitles and
    /// AI & MCP sections came out empty — so it is only the fallback.
    private static func saveWindow(_ window: NSWindow, _ name: String, in dir: URL) async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let scWindow = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
                throw CocoaError(.fileNoSuchFile)
            }
            let config = SCStreamConfiguration()
            let scale = window.backingScaleFactor
            config.width = Int(window.frame.width * scale)
            config.height = Int(window.frame.height * scale)
            config.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(desktopIndependentWindow: scWindow), configuration: config)
            let rep = NSBitmapImageRep(cgImage: image)
            try rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name).png"))
        } catch {
            save(window.contentView, name, in: dir)
        }
    }

    private static func save(_ view: NSView?, _ name: String, in dir: URL) {
        guard let view, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name).png"))
    }
}
