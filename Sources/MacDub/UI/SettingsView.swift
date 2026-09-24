import AppKit
import SwiftUI
import Speech
import Translation
import AVFAudio
import MacDubCore

/// The Settings window (⌘,): classic macOS preferences with a toolbar of categories.
struct SettingsView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        TabView {
            GeneralSettingsTab().tabItem { Label("General", systemImage: "gearshape") }
            CaptureSettingsTab().tabItem { Label("Capture", systemImage: "waveform") }
            SpeechSettingsTab().tabItem { Label("Speech", systemImage: "text.bubble") }
            VoiceSettingsTab().tabItem { Label("Voice", systemImage: "speaker.wave.2") }
            SubtitlesSettingsTab().tabItem { Label("Subtitles", systemImage: "captions.bubble") }
            AISettingsTab().tabItem { Label("AI & MCP", systemImage: "sparkles") }
            ExtensionsSettingsTab().tabItem { Label("Extensions", systemImage: "puzzlepiece.extension") }
            PermissionsSettingsTab().tabItem { Label("Permissions", systemImage: "lock.shield") }
        }
        .frame(width: Self.width)
        // Without an ideal height SwiftUI opens the window at the TabView's reported minimum
        // (~470 pt) and the longer forms show a scroll bar on screens with plenty of room. An
        // ideal height opens it showing the content; `maxHeight` infinity keeps it resizable.
        .frame(height: Self.idealHeight)
        .environmentObject(state)
    }

    private static let width: CGFloat = 640
    /// Below this the forms are unreadable; scrolling is the right answer there.
    private static let minHeight: CGFloat = 420

    /// Opening height: what the content needs, capped by this Mac's screen.
    ///
    /// A fixed number is wrong at both ends — 760 pt doesn't fit a 13" laptop, 470 looks tiny
    /// on a large display — so measure the screen and leave room for the menu bar and Dock.
    private static var idealHeight: CGFloat {
        let available = NSScreen.main?.visibleFrame.height ?? 900
        return min(760, max(minHeight, available - 160))
    }
}

private struct GeneralSettingsTab: View {
    @EnvironmentObject private var state: AppState
    private var settings: Settings { state.settings }

    var body: some View {
        Form {
            SystemStatusSection()
            Section("Interface") {
                Picker("Language", selection: settings.binding(\.interfaceLanguage)) {
                    ForEach(InterfaceLanguage.allCases) { lang in Text(lang.title).tag(lang.rawValue) }
                }
                .onChange(of: settings.interfaceLanguage) { _, new in (InterfaceLanguage(rawValue: new) ?? .system).apply() }
                Text("Takes effect after relaunching MacDub. Translations live in Sources/MacDub/Resources — contributions welcome.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Menu bar") {
                Toggle("Hide Dock icon (menu bar only)", isOn: settings.binding(\.hideDockIcon))
                    .help("MacDub keeps running in the menu bar; use its icon or ⌘, from the pill to come back.")
                Toggle("Open at login", isOn: $state.launchAtLogin)
                Toggle("Global shortcuts: ⌃⌥D start/stop · ⌃⌥S subtitle bar", isOn: settings.binding(\.globalHotKeys))
            }
            Section("Sessions") {
                Toggle("Save sessions to History (⌘Y)", isOn: settings.binding(\.saveSessions))
                Toggle("Record the original audio (playback and export from History)", isOn: settings.binding(\.recordAudio))
                    .disabled(!settings.saveSessions)
                    .help("Mono AAC at 48 kbit/s: about 20 MB per hour, in ~/.macdub/audio.")
            }
            Section("Storage") {
                LabeledContent("Recorded audio in ~/.macdub") {
                    HStack(spacing: 8) {
                        Text(state.storageSize.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "…")
                            .monospacedDigit()
                        Button { state.refreshStorageSize() } label: { Image(systemName: "arrow.clockwise") }
                            .iconButtonHelp("Refresh")
                            .buttonStyle(.borderless)
                        Button("Show in Finder") {
                            try? FileManager.default.createDirectory(at: MacDubPaths.dataDirectory, withIntermediateDirectories: true)
                            NSWorkspace.shared.activateFileViewerSelecting([MacDubPaths.dataDirectory])
                        }
                    }
                }
                HStack {
                    Button("Delete all sessions…") { confirmDeleteSessions = true }
                        .disabled(state.sessions.isEmpty)
                    Text(LF("%lld sessions", state.sessions.count)).font(.caption).foregroundStyle(.secondary)
                }
                .confirmationDialog("Delete all saved sessions and their audio?", isPresented: $confirmDeleteSessions, titleVisibility: .visible) {
                    Button("Delete all sessions", role: .destructive) { state.deleteAllSessions() }
                }
            }
            Section("Reset") {
                Button("Factory reset…") { confirmFactoryReset = true }
                    .disabled(state.phase != .idle)
                Text("Erases every preference, saved session and recorded audio, then relaunches MacDub.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .confirmationDialog("Reset MacDub to factory settings?", isPresented: $confirmFactoryReset, titleVisibility: .visible) {
                Button("Erase everything and relaunch", role: .destructive) { Task { await state.factoryReset() } }
            } message: {
                Text("Preferences, History (transcripts and audio) and the MCP live state are deleted. This cannot be undone.")
            }
        }
        .formStyle(.grouped)
        .onAppear { state.refreshStorageSize(); state.refreshSessions() }
    }

    @State private var confirmDeleteSessions = false
    @State private var confirmFactoryReset = false
}

/// Recognition engine choice plus what this Mac detected and what is running. Shown under
/// Capture › Engine and Speech › Recognition.
private struct RecognitionEnginePicker: View {
    @EnvironmentObject private var state: AppState
    private var settings: Settings { state.settings }

    var body: some View {
        Picker("Recognition engine", selection: settings.binding(\.recognitionEngine)) {
            ForEach(RecognitionEngineKind.available) { kind in Text(kind.title).tag(kind.rawValue) }
        }
        .disabled(state.phase != .idle)
        .help("Automatic uses SpeechAnalyzer on macOS 26 (better punctuation, lower latency) and falls back to SFSpeechRecognizer otherwise or if it fails.")
        VStack(alignment: .leading, spacing: 2) {
            if let reason = RecognitionEngineKind.analyzerUnavailableReason {
                Text(LF("SpeechAnalyzer not available: %@. Using SFSpeechRecognizer.", reason))
            } else {
                Text("SpeechAnalyzer detected on this Mac.")
            }
            if let engine = state.activeRecognitionEngine {
                Text(engine == "analyzer" ? L("Running: SpeechAnalyzer") : L("Running: SFSpeechRecognizer"))
            }
        }
        .font(.caption).foregroundStyle(.secondary)
    }
}

/// Settings › General › Status: the Mac, the OS, and which engines this build can use.
private struct SystemStatusSection: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        Section("Status") {
            LabeledContent("Chip", value: SystemInfo.chip)
            LabeledContent("Processor", value: "\(SystemInfo.cores) · \(SystemInfo.architecture)")
            LabeledContent("Memory", value: SystemInfo.memory)
            LabeledContent("System", value: SystemInfo.macOSVersion)
            LabeledContent("Speech recognition") { recognitionStatus }
            LabeledContent("Apple Intelligence") { appleIntelligenceStatus }
            if !SystemInfo.builtWithMacOS26SDK {
                Text("This build was compiled without the macOS 26 SDK: SpeechAnalyzer and Apple Intelligence are disabled even on macOS 26.")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder private var recognitionStatus: some View {
        let running = state.activeRecognitionEngine.map { $0 == "analyzer" ? "SpeechAnalyzer" : "SFSpeechRecognizer" }
        if RecognitionEngineKind.analyzerSupported {
            status(ok: true, running.map { LF("%@ · running", $0) } ?? L("SpeechAnalyzer available"))
        } else {
            status(ok: false, running.map { LF("%@ · running", $0) } ?? "SFSpeechRecognizer")
        }
    }

    @ViewBuilder private var appleIntelligenceStatus: some View {
        switch LocalLLM.appleStatus {
        case .available: status(ok: true, L("Available (on-device model)"))
        case .notEnabled: status(ok: false, L("Turned off in System Settings"))
        case .deviceNotEligible: status(ok: false, L("Not supported on this Mac"))
        case .modelNotReady: status(ok: false, L("Model downloading…"))
        case .requiresMacOS26: status(ok: false, L("Requires macOS 26"))
        case .notInBuild: status(ok: false, L("Not included in this build"))
        case .unknown: status(ok: false, L("Unavailable"))
        }
    }

    private func status(ok: Bool, _ text: String) -> some View {
        Label(text, systemImage: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
            .foregroundStyle(ok ? .green : .orange)
    }
}

private struct CaptureSettingsTab: View {
    @EnvironmentObject private var state: AppState
    private var settings: Settings { state.settings }

    var body: some View {
        Form {
            Section("Engine") {
                Picker("Capture engine", selection: settings.binding(\.captureEngine)) {
                    Text("Core Audio tap · can lower the original").tag("tap")
                    Text("ScreenCaptureKit · original untouched").tag("sck")
                }
                .disabled(state.phase != .idle)
                if settings.usesProcessTap {
                    Text("The tap needs the app to be playing audio when you press Start.").font(.caption).foregroundStyle(.secondary)
                }
                RecognitionEnginePicker()
            }
            if settings.usesProcessTap {
                Section("Original audio") {
                    LabeledContent("Original audio") {
                        HStack {
                            Slider(value: settings.binding(\.originalVolume), in: 0...1)
                            Text("\(Int(settings.originalVolume * 100)) %").monospacedDigit().frame(width: 44, alignment: .trailing)
                        }
                    }
                    .help("How loud the video's own audio stays under the translated voice.")
                    Toggle("Only lower it while the voice is speaking", isOn: settings.binding(\.duckOnlyWhileSpeaking))
                }
            }
            Section("Automation") {
                Toggle("Start dubbing when the app starts playing audio", isOn: settings.binding(\.autoStartWhenAudio))
                    .help("Watches the selected application while MacDub is idle and starts automatically.")
                LabeledContent("Silence watchdog") {
                    HStack {
                        Slider(value: settings.binding(\.silenceTimeout), in: 0...120, step: 5)
                        Text(settings.silenceTimeout == 0 ? L("off") : String(format: "%.0f s", settings.silenceTimeout)).monospacedDigit().frame(width: 44)
                    }
                }
                .help("After this long without sound from the captured app, MacDub shows a notice (or stops, below).")
                Toggle("Stop dubbing when the app goes silent", isOn: settings.binding(\.stopOnSilence)).disabled(settings.silenceTimeout == 0)
            }
        }
        .formStyle(.grouped)
    }
}

private struct SpeechSettingsTab: View {
    @EnvironmentObject private var state: AppState
    private var settings: Settings { state.settings }

    var body: some View {
        Form {
            Section("Recognition") {
                RecognitionEnginePicker()
                LabeledContent("Silence cut-off") {
                    HStack {
                        Slider(value: settings.binding(\.silenceFlushInterval), in: 0.5...3, step: 0.1)
                        Text(String(format: "%.1f s", locale: .current, settings.silenceFlushInterval)).monospacedDigit().frame(width: 44)
                    }
                }
                .help("How long to wait after the speaker pauses before translating the pending words.")
                .disabled(state.phase != .idle)
            }
            Section("Translation") {
                switch state.capabilities.translationStatus {
                case .installed: Label("Model installed · offline", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                case .supported:
                    HStack {
                        Label("Model not downloaded yet (one-time download).", systemImage: "arrow.down.circle.fill").foregroundStyle(.orange)
                        Spacer()
                        Button("Prepare translation") { state.prepareTranslation() }
                    }
                case .unsupported: Label("This language pair is not supported.", systemImage: "xmark.circle.fill").foregroundStyle(.red)
                case .none: Text("Checking…").foregroundStyle(.secondary)
                @unknown default: EmptyView()
                }
                Text("Languages are chosen on the Dubbing screen.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct VoiceSettingsTab: View {
    @EnvironmentObject private var state: AppState
    private var settings: Settings { state.settings }

    var body: some View {
        Form {
            Section("Voice") {
                HStack {
                    VoicePickerView(voices: state.voices, selection: settings.binding(\.voiceIdentifier)).equatable()
                    Button { state.reloadVoices() } label: { Image(systemName: "arrow.clockwise") }
                        .iconButtonHelp("Reload the voice list after downloading voices in System Settings")
                }
                Text("👤 Personal Voice · 🟢 Premium · 🟡 Enhanced · ⚪ Compact · ⚫ Novelty. Download Enhanced/Premium voices in System Settings; Siri voices are reserved by Apple and never appear here.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Test voice") { state.testVoice() }
                    Button("Manage voices…") { SystemSettings.open(SystemSettings.spokenContent) }
                }
            }
            Section("Personal Voice") {
                let hasPersonal = state.voices.contains(where: VoiceSynthesisManager.isPersonal)
                switch state.personalVoiceStatus {
                case .unsupported:
                    LabeledContent("Dub with the voice you recorded in Accessibility › Personal Voice") {
                        Button("Allow…") {}.disabled(true)
                    }
                    Text("Personal Voice isn't available on this Mac. It needs macOS 14 or later, and creating one needs a Mac with Apple silicon.")
                        .font(.caption).foregroundStyle(.secondary)
                case .authorized:
                    Text(hasPersonal
                         ? "👤 Your Personal Voice is in the list above."
                         : "MacDub may use your Personal Voice, but none was recorded in the dubbing language. Personal Voice speaks the language it was recorded in.")
                        .font(.caption).foregroundStyle(.secondary)
                case .denied:
                    LabeledContent("Not allowed") {
                        Button("Open System Settings") { state.requestPersonalVoice() }
                    }
                    Text("Turn MacDub on under Accessibility › Personal Voice › Allow apps to use your Personal Voice.")
                        .font(.caption).foregroundStyle(.secondary)
                default:
                    LabeledContent("Dub with the voice you recorded in Accessibility › Personal Voice") {
                        Button("Allow…") { state.requestPersonalVoice() }
                    }
                }
                if state.personalVoiceStatus != .unsupported, !hasPersonal {
                    LabeledContent("Record your voice (about 15 minutes of reading aloud); only System Settings can create it") {
                        Button("Create in System Settings…") { state.openPersonalVoiceSettings() }
                    }
                }
            }
            Section("Playback") {
                LabeledContent("Rate") {
                    HStack {
                        Slider(value: settings.binding(\.speechRate), in: 0.3...0.75)
                        Text(String(format: "%.2f", locale: .current, settings.speechRate)).monospacedDigit().frame(width: 36)
                    }
                }
                LabeledContent("Volume") { Slider(value: settings.binding(\.volume), in: 0.2...1) }
            }
            Section("Keeping up") {
                LabeledContent("Catch-up speed-up") {
                    HStack {
                        Slider(value: settings.binding(\.catchUpBoost), in: 0...0.3, step: 0.05)
                        Text(settings.catchUpBoost == 0 ? L("off") : "+\(Int(settings.catchUpBoost * 100)) %").monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
                .help("How much faster each sentence is read per sentence still waiting in the queue. 0 keeps the voice at a constant speed; the queue is then trimmed by Max delay instead.")
                Stepper("Skip backlog beyond \(settings.maxBacklog) sentences", value: settings.binding(\.maxBacklog), in: 1...20)
                LabeledContent("Max delay") {
                    HStack {
                        Slider(value: settings.binding(\.maxSpokenLag), in: 2...15, step: 0.5)
                        Text(String(format: "%.1f s", locale: .current, settings.maxSpokenLag)).monospacedDigit().frame(width: 44)
                    }
                }
                .help("Sentences older than this are shown as subtitles but not spoken when the voice is behind.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct SubtitlesSettingsTab: View {
    @EnvironmentObject private var state: AppState
    private var settings: Settings { state.settings }

    var body: some View {
        Form {
            Section("Transcript") {
                Toggle("Include original text", isOn: settings.binding(\.showOriginalInSubtitles))
                Toggle("Highlight the words being spoken", isOn: settings.binding(\.highlightSpokenWords))
                Toggle("Auto-scroll", isOn: settings.binding(\.autoScrollSubtitles))
            }
            Section("Floating bar") {
                Stepper("Lines: \(settings.pillLines)", value: settings.binding(\.pillLines), in: 1...6)
                LabeledContent("Width") { Slider(value: settings.binding(\.pillWidth), in: 520...1400, step: 20) }
                LabeledContent("Text size") { Slider(value: settings.binding(\.pillFontSize), in: 14...34, step: 1) }
            }
        }
        .formStyle(.grouped)
    }
}

private struct AISettingsTab: View {
    @EnvironmentObject private var state: AppState
    private var settings: Settings { state.settings }

    var body: some View {
        Form {
            Section("MCP server") {
                HStack {
                    Toggle("Also serve over HTTP on port", isOn: settings.binding(\.mcpHTTPEnabled))
                    TextField("", value: settings.binding(\.mcpHTTPPort), format: .number.grouping(.never)).frame(width: 70).disabled(settings.mcpHTTPEnabled)
                }
                .help("Streamable HTTP transport at http://127.0.0.1:<port>/mcp (localhost only) for clients that cannot spawn a stdio server, or behind a tunnel for remote assistants.")
                if let status = state.mcpHTTPStatus { Text(status).font(.caption).foregroundStyle(.secondary) }
                LabeledContent("Keep audio for snippets") {
                    HStack {
                        Slider(value: settings.binding(\.audioBufferSeconds), in: 0...120, step: 10)
                        Text(settings.audioBufferSeconds == 0 ? L("off") : String(format: "%.0f s", settings.audioBufferSeconds)).monospacedDigit().frame(width: 44)
                    }
                }
                .help("Seconds of captured audio kept in memory so an assistant can request get_audio_snippet. Never written to disk unless asked.")
                Text("Registration with Claude Code, Claude Desktop and Codex, and summaries, are on the AI & MCP screen.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct PermissionsSettingsTab: View {
    @EnvironmentObject private var state: AppState
    @State private var confirmResetPermissions = false

    var body: some View {
        Form {
            Section("Permissions") {
                row("Screen & System Audio Recording", granted: state.capabilities.screenRecording) {
                    Button("Request") { state.requestScreenRecording() }
                }
                row("Speech Recognition", granted: state.capabilities.speechAuthorization == .authorized) {
                    if state.capabilities.speechAuthorization == .notDetermined {
                        Button("Request") { state.requestSpeechAuthorization() }
                    } else {
                        Button("Open Settings") { SystemSettings.open(SystemSettings.speechRecognition) }
                    }
                }
                if !state.capabilities.screenRecording {
                    Text("After enabling Screen Recording, quit and relaunch MacDub.").font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Reset permissions and relaunch…") { confirmResetPermissions = true }
                        .disabled(state.phase != .idle)
                    Spacer()
                }
                Text("Forgets MacDub's Screen & System Audio Recording and Speech Recognition grants, relaunches the app and lets macOS ask again. Use it when a permission shows as granted but capture or recognition still fails.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .confirmationDialog("Reset MacDub's permissions?", isPresented: $confirmResetPermissions, titleVisibility: .visible) {
                Button("Reset and relaunch", role: .destructive) { Task { await state.resetPermissionsAndRelaunch() } }
            } message: {
                Text("MacDub relaunches and macOS asks for each permission again. You have to allow them again.")
            }
            Section("On-device models") {
                row("On-device speech model for the spoken language", granted: state.capabilities.sourceOnDevice) {
                    Button("Open Dictation Settings") { SystemSettings.open(SystemSettings.dictation) }
                }
                row("Translation model", granted: state.capabilities.translationStatus == .installed) {
                    Button("Prepare translation") { state.prepareTranslation() }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func row<T: View>(_ title: LocalizedStringKey, granted: Bool, @ViewBuilder trailing: () -> T) -> some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle.fill").foregroundStyle(granted ? .green : .red)
            Text(title)
            Spacer()
            if !granted { trailing() }
        }
    }
}

extension SettingsView {
    /// Each tab on its own, for `UISnapshots` (the tab structs are private to this file).
    static var snapshotTabs: [(name: String, view: AnyView)] {
        [("general", AnyView(GeneralSettingsTab())), ("capture", AnyView(CaptureSettingsTab())),
         ("speech", AnyView(SpeechSettingsTab())), ("voice", AnyView(VoiceSettingsTab())),
         ("subtitles", AnyView(SubtitlesSettingsTab())), ("ai", AnyView(AISettingsTab())), ("extensions", AnyView(ExtensionsSettingsTab())),
         ("permissions", AnyView(PermissionsSettingsTab()))]
    }
}

/// The Chrome extension for live translation in Meet: what it does, whether it is talking to
/// MacDub, and one click to install it.
private struct ExtensionsSettingsTab: View {
    @EnvironmentObject private var state: AppState
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                HStack(alignment: .top, spacing: 12) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 40, height: 40)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("MacDub · Live translation for Meet").font(.headline)
                        Text("For live translation in Google Meet on Chrome: switches the call's microphone to the translated voice by itself, posts the translation in the chat and brings the chat messages to MacDub. It only talks to MacDub on this Mac.")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                LabeledContent("Status") {
                    if let seen = state.extensionLastSeen, Date().timeIntervalSince(seen) < 30 {
                        Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else if let seen = state.extensionLastSeen {
                        Text(LF("Last seen %@", seen.formatted(date: .omitted, time: .shortened))).foregroundStyle(.secondary)
                    } else {
                        Text("Not seen yet (it connects while live translation runs)").foregroundStyle(.secondary)
                    }
                }
                if let version = ChromeExtension.version {
                    LabeledContent("Version") { Text(version).monospacedDigit() }
                }
                HStack {
                    Button(ChromeExtension.webStoreID == nil ? "Install in Chrome…" : "Get it from the Chrome Web Store") {
                        do { try ChromeExtension.install(); error = nil } catch { self.error = error.localizedDescription }
                    }
                    .disabled(ChromeExtension.chromeURL == nil && ChromeExtension.webStoreID == nil)
                    if ChromeExtension.chromeURL == nil { Text("Google Chrome is not installed.").font(.caption).foregroundStyle(.orange) }
                }
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
            }
            if ChromeExtension.webStoreID == nil {
                Section("Install (developer mode, until it is in the Chrome Web Store)") {
                    Text("1. “Install in Chrome…” opens the extension's folder and Chrome's Extensions page.")
                    Text("2. Turn on Developer mode (top right).")
                    Text("3. Load unpacked › choose the chrome-extension folder (⌘⇧G and paste the path below).")
                    Text("4. Reload the Meet tab. After a MacDub update, press ↻ on the extension's card.")
                    HStack {
                        Text(ChromeExtension.folder.path).font(.caption.monospaced()).textSelection(.enabled)
                        Spacer()
                        Button("Copy path") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(ChromeExtension.folder.path, forType: .string)
                        }
                        .controlSize(.small)
                    }
                }
                .font(.callout)
            }
        }
        .formStyle(.grouped)
    }
}
