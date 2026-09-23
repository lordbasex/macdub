import SwiftUI
import AppKit

/// Entry point: the headless recognition benchmark (see `RecognitionBenchmark`) runs before
/// anything of the app — `AppState`, windows, capture — is created.
@main
enum MacDubMain {
    static func main() {
        // Writing to a pipe whose reader is gone (a CLI that quit early) must fail, not kill the app.
        signal(SIGPIPE, SIG_IGN)
        if RecognitionBenchmark.isRequested { RecognitionBenchmark.runAndExit() }
        waitForReplacedInstance()
        if let running = otherInstance() {
            // Two instances would capture, recognize and speak the same audio twice and fight
            // over the MCP live state; bring the running one forward instead.
            running.activate()
            exit(0)
        }
        MacDubApp.main()
    }

    /// `--relaunched-from <pid>`: this copy replaces that process (see `AppState.relaunch`).
    static let relaunchArgument = "--relaunched-from"

    /// When relaunched, wait (up to 15 s) for the old process to finish quitting.
    private static func waitForReplacedInstance() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: relaunchArgument), i + 1 < args.count, let pid = pid_t(args[i + 1]) else { return }
        let deadline = Date().addingTimeInterval(15)
        while kill(pid, 0) == 0, Date() < deadline { usleep(100_000) }
    }

    /// Another MacDub already running for this user (any copy of the app: build/, /Applications…).
    /// Benchmark runs never finish launching (no UI), so they don't count.
    private static func otherInstance() -> NSRunningApplication? {
        guard let id = Bundle.main.bundleIdentifier else { return nil }
        return NSRunningApplication.runningApplications(withBundleIdentifier: id).first {
            $0.processIdentifier != getpid() && $0.isFinishedLaunching && !$0.isTerminated
        }
    }
}

struct MacDubApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var state = AppState.shared

    var body: some Scene {
        Window("MacDub", id: AppState.mainWindowID) {
            ContentView()
                .environmentObject(state)
                .frame(minWidth: 1040, minHeight: 700)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1120, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appInfo) {
                Button("About MacDub") { state.showAbout() }
            }
            CommandMenu(Text("Dubbing")) {
                Button(state.phase == .running ? L("Stop") : L("Start")) { state.toggle() }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(state.isBusy)
                Button("Skip Speech Backlog") { state.skipBacklog() }
                    .keyboardShortcut("k", modifiers: .command)
                Button(state.isSubtitleBarVisible ? L("Hide Subtitle Bar") : L("Show Subtitle Bar")) { state.toggleSubtitleBar() }
                    .keyboardShortcut("b", modifiers: .command)
                Divider()
                Button("Export Subtitles (.srt)…") { state.exportTranscript(format: .srt, content: .translated) }
                    .keyboardShortcut("e", modifiers: .command)
                    .disabled(state.segments.isEmpty)
                Button("Export Markdown (.md)…") { state.exportTranscript(format: .md, content: .both) }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(state.segments.isEmpty)
                Button("Clear Transcript") { state.clearTranscript() }
                    .keyboardShortcut("l", modifiers: .command)
                Divider()
                Button("Session History…") { state.showHistory() }
                    .keyboardShortcut("y", modifiers: .command)
            }
        }

        // Standard macOS preferences window (⌘,), with a toolbar of categories.
        SwiftUI.Settings { // our `Settings` model type shadows the scene name
            SettingsView()
                .environmentObject(state)
        }

        // Always-on-top subtitle pill you can drop over the video you are watching.
        Window("Subtitle Bar", id: FloatingSubtitlesView.windowID) {
            FloatingSubtitlesView()
                .environmentObject(state)
        }
        .windowStyle(.plain)
        .windowLevel(.floating)
        .windowBackgroundDragBehavior(.enabled)
        .windowResizability(.contentSize)
        .restorationBehavior(.disabled)
        .defaultWindowPlacement { content, context in
            // Bottom-centre of the main display, like a subtitle track.
            let size = content.sizeThatFits(.unspecified)
            let display = context.defaultDisplay.visibleRect
            return WindowPlacement(CGPoint(x: display.midX - size.width / 2, y: display.maxY - size.height - 40), size: size)
        }
    }
}
