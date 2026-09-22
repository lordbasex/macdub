import SwiftUI

@main
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
