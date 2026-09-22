import SwiftUI
import Speech
import Translation
import AVFAudio

struct ControlPanelView: View {
    @EnvironmentObject private var state: AppState

    private var settings: Settings { state.settings }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                sourceSection
                originalAudioSection
                translationSection
                voiceSection
                subtitlesSection
                advancedSection
                permissionsSection
                AIIntegrationSection()
                interfaceSection
            }
            .formStyle(.grouped)

            Divider()
            footer
        }
    }

    // MARK: Sections

    private var sourceSection: some View {
        Section("Source") {
            HStack {
                Picker("Application", selection: $state.selectedTargetID) {
                    Text("Choose…").tag(String?.none)
                    ForEach(state.targets) { t in
                        if t.isSystem {
                            Text("🔊 " + t.name).tag(Optional(t.id))
                            Divider()
                        } else {
                            Text(t.name).tag(Optional(t.id))
                        }
                    }
                }
                .help("One app (Zoom, Teams, VLC, a browser…) or the entire system audio. The microphone is never captured.")
                Button {
                    Task { await state.refreshTargets() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh running applications")
            }
            .disabled(state.phase != .idle)

            Picker("Spoken language", selection: settings.binding(\.sourceLocaleID)) {
                ForEach(state.sourceLocales, id: \.identifier) { locale in
                    let onDevice = SpeechAndTranslationManager.supportsOnDevice(locale)
                    Text(SpeechAndTranslationManager.displayName(locale) + (onDevice ? "" : "  · " + L("needs download")))
                        .tag(locale.identifier)
                }
            }
            .disabled(state.phase != .idle)

            if !state.capabilities.sourceOnDevice {
                statusRow(icon: "exclamationmark.triangle.fill", tint: .orange,
                          text: L("No on-device model for this language. Add it under Keyboard › Dictation.")) {
                    Button("Open Dictation Settings") { SystemSettings.open(SystemSettings.dictation) }
                }
            }
        }
    }

    private var originalAudioSection: some View {
        Section {
            Picker("Capture engine", selection: settings.binding(\.captureEngine)) {
                Text("Core Audio tap · can lower the original").tag("tap")
                Text("ScreenCaptureKit · original untouched").tag("sck")
            }
            .disabled(state.phase != .idle)

            if settings.usesProcessTap {
                LabeledContent("Original audio") {
                    HStack {
                        Image(systemName: "speaker.wave.1").foregroundStyle(.secondary)
                        Slider(value: settings.binding(\.originalVolume), in: 0...1)
                        Text("\(Int(settings.originalVolume * 100)) %").monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
                .help("How loud the video's own audio stays under the translated voice.")
                Toggle("Only lower it while the voice is speaking", isOn: settings.binding(\.duckOnlyWhileSpeaking))
                if state.activeEngine == "sck" {
                    statusRow(icon: "exclamationmark.triangle.fill", tint: .orange,
                              text: L("Fell back to ScreenCaptureKit for this session.")) { EmptyView() }
                }
            }
        } header: {
            Text("Original audio")
        } footer: {
            if settings.usesProcessTap {
                Text("The tap needs the app to be playing audio when you press Start.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var translationSection: some View {
        Section("Translation") {
            Picker("Translate to", selection: settings.binding(\.targetLanguageID)) {
                ForEach(state.targetLanguages, id: \.minimalIdentifier) { lang in
                    Text(TranslationCatalog.displayName(lang)).tag(lang.minimalIdentifier)
                }
            }
            .disabled(state.phase != .idle)

            switch state.capabilities.translationStatus {
            case .installed:
                statusRow(icon: "checkmark.circle.fill", tint: .green, text: L("Model installed · offline")) {
                    translationSessionBadge
                }
            case .supported:
                statusRow(icon: "arrow.down.circle.fill", tint: .orange,
                          text: L("Model not downloaded yet (one-time download).")) {
                    Button("Prepare translation") { state.prepareTranslation() }
                }
            case .unsupported:
                statusRow(icon: "xmark.circle.fill", tint: .red, text: L("This language pair is not supported.")) { EmptyView() }
            case .none:
                statusRow(icon: "circle.dotted", tint: .secondary, text: L("Checking…")) { EmptyView() }
            @unknown default:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private var translationSessionBadge: some View {
        switch state.translation.status {
        case .ready: Text("session ready").font(.caption).foregroundStyle(.secondary)
        case .preparing: ProgressView().controlSize(.small)
        case .unavailable(let msg): Text(msg).font(.caption).foregroundStyle(.red).lineLimit(2)
        case .idle: EmptyView()
        }
    }

    private var voiceSection: some View {
        Section("Voice") {
            Toggle("Speak the translation", isOn: settings.binding(\.speakTranslation))

            HStack {
                VoicePickerView(voices: state.voices, selection: settings.binding(\.voiceIdentifier))
                    .equatable()
                Button {
                    state.reloadVoices()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Reload the voice list after downloading voices in System Settings")
            }
            Text("🟢 Premium · 🟡 Enhanced · ⚪ Compact · ⚫ Novelty. Download Enhanced/Premium voices in System Settings; Siri voices are reserved by Apple and never appear here.")
                .font(.caption).foregroundStyle(.secondary)

            LabeledContent("Rate") {
                HStack {
                    Slider(value: settings.binding(\.speechRate), in: 0.3...0.75)
                    Text(String(format: "%.2f", settings.speechRate)).monospacedDigit().frame(width: 36)
                }
            }
            LabeledContent("Volume") {
                Slider(value: settings.binding(\.volume), in: 0.2...1)
            }
            LabeledContent("Catch-up speed-up") {
                HStack {
                    Slider(value: settings.binding(\.catchUpBoost), in: 0...0.3, step: 0.05)
                    Text(settings.catchUpBoost == 0 ? L("off") : "+\(Int(settings.catchUpBoost * 100)) %")
                        .monospacedDigit().frame(width: 44, alignment: .trailing)
                }
            }
            .help("How much faster each sentence is read per sentence still waiting in the queue. 0 keeps the voice at a constant speed; the queue is then trimmed by Max delay instead.")
            Stepper("Skip backlog beyond \(settings.maxBacklog) sentences", value: settings.binding(\.maxBacklog), in: 1...20)
                .help("When the dub falls this many sentences behind, older ones are dropped to catch up.")
            LabeledContent("Max delay") {
                HStack {
                    Slider(value: settings.binding(\.maxSpokenLag), in: 2...15, step: 0.5)
                    Text(String(format: "%.1f s", settings.maxSpokenLag)).monospacedDigit().frame(width: 44)
                }
            }
            .help("Sentences older than this are shown as subtitles but not spoken when the voice is behind.")

            HStack {
                Button("Test voice") { state.testVoice() }
                Button("Manage voices…") { SystemSettings.open(SystemSettings.spokenContent) }
                    .help("Download higher quality voices in System Settings › Accessibility › Spoken Content")
            }
        }
    }

    private var subtitlesSection: some View {
        Section("Subtitles") {
            Toggle("Show subtitles panel", isOn: settings.binding(\.showSubtitles))
            Toggle("Include original text", isOn: settings.binding(\.showOriginalInSubtitles))
            Toggle("Highlight the words being spoken", isOn: settings.binding(\.highlightSpokenWords))
            Button(state.isSubtitleBarVisible ? L("Hide subtitle bar") : L("Show subtitle bar")) { state.toggleSubtitleBar() }
                .help("Floating pill with the last translated lines, Stop and quick settings (⌘B)")
        }
    }

    private var advancedSection: some View {
        Section("Advanced") {
            Picker("Recognition engine", selection: settings.binding(\.recognitionEngine)) {
                ForEach(RecognitionEngineKind.available) { kind in
                    Text(kind.title).tag(kind.rawValue)
                }
            }
            .disabled(state.phase != .idle)
            .help("Automatic uses SpeechAnalyzer on macOS 26 (better punctuation, lower latency) and falls back to SFSpeechRecognizer otherwise or if it fails.")
            if let engine = state.activeRecognitionEngine {
                Text(engine == "analyzer" ? L("Running: SpeechAnalyzer") : L("Running: SFSpeechRecognizer"))
                    .font(.caption).foregroundStyle(.secondary)
            }

            LabeledContent("Silence watchdog") {
                HStack {
                    Slider(value: settings.binding(\.silenceTimeout), in: 0...120, step: 5)
                    Text(settings.silenceTimeout == 0 ? L("off") : String(format: "%.0f s", settings.silenceTimeout))
                        .monospacedDigit().frame(width: 44)
                }
            }
            .help("After this long without sound from the captured app, MacDub shows a notice (or stops, below).")
            Toggle("Stop dubbing when the app goes silent", isOn: settings.binding(\.stopOnSilence))
                .disabled(settings.silenceTimeout == 0)
            if let quiet = state.silentFor, quiet >= 5 {
                Text(LF("No audio for %lld s", Int(quiet))).font(.caption).foregroundStyle(.orange)
            }

            Toggle("Global shortcuts: ⌃⌥D start/stop · ⌃⌥S subtitle bar", isOn: settings.binding(\.globalHotKeys))
            Toggle("Save sessions to History (⌘Y)", isOn: settings.binding(\.saveSessions))
            LabeledContent("Silence cut-off") {
                HStack {
                    Slider(value: settings.binding(\.silenceFlushInterval), in: 0.5...3, step: 0.1)
                    Text(String(format: "%.1f s", settings.silenceFlushInterval)).monospacedDigit().frame(width: 44)
                }
            }
            .help("How long to wait after the speaker pauses before translating the pending words.")
            .disabled(state.phase != .idle)
        }
    }

    private var permissionsSection: some View {
        Section("Permissions") {
            permissionRow(L("Screen & System Audio Recording"), granted: state.capabilities.screenRecording) {
                Button("Request") { state.requestScreenRecording() }
            }
            permissionRow(L("Speech Recognition"), granted: state.capabilities.speechAuthorization == .authorized) {
                if state.capabilities.speechAuthorization == .notDetermined {
                    Button("Request") { state.requestSpeechAuthorization() }
                } else {
                    Button("Open Settings") { SystemSettings.open(SystemSettings.speechRecognition) }
                }
            }
            if !state.capabilities.screenRecording {
                Text("After enabling Screen Recording, quit and relaunch MacDub.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var interfaceSection: some View {
        Section("Interface") {
            Toggle("Hide Dock icon (menu bar only)", isOn: settings.binding(\.hideDockIcon))
                .help("MacDub keeps running in the menu bar; use its icon or ⌘, from the pill to come back.")
            Toggle("Open at login", isOn: $state.launchAtLogin)
            Toggle("Start dubbing when the app starts playing audio", isOn: settings.binding(\.autoStartWhenAudio))
                .help("Watches the selected application while MacDub is idle and starts automatically.")
            Picker("Language", selection: settings.binding(\.interfaceLanguage)) {
                ForEach(InterfaceLanguage.allCases) { lang in
                    Text(lang.title).tag(lang.rawValue)
                }
            }
            .onChange(of: settings.interfaceLanguage) { _, new in
                (InterfaceLanguage(rawValue: new) ?? .system).apply()
            }
            Text("Takes effect after relaunching MacDub. Translations live in Sources/MacDub/Resources — contributions welcome.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 10) {
            if let message = state.errorMessage {
                VStack(alignment: .leading, spacing: 4) {
                    Label(message, systemImage: "exclamationmark.octagon.fill")
                        .foregroundStyle(.red)
                    if let suggestion = state.errorSuggestion {
                        Text(suggestion).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                .onTapGesture { state.clearError() }
            }
            if let notice = state.notice {
                Label(notice, systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 12) {
                Button {
                    state.toggle()
                } label: {
                    Label {
                        Text(state.phase == .running ? L("Stop") : L("Start dubbing"))
                    } icon: {
                        Image(systemName: state.phase == .running ? "stop.fill" : "play.fill")
                    }
                    .frame(minWidth: 140)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .tint(state.phase == .running ? .red : .accentColor)
                .disabled(state.isBusy || (state.phase == .idle && state.selectedTarget == nil))

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Circle().fill(phaseColor).frame(width: 8, height: 8)
                        Text(phaseText).font(.callout).lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 8)
                        if state.latency.samples > 0 {
                            Text(LF("delay %.1f s · avg %.1f s · translate %.1f s",
                                    state.latency.lastSpoken, state.latency.spoken, state.latency.translation))
                                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                                .help("Seconds from the end of the original sentence to the voice starting it (last / mean of last 10 / translation share).")
                        }
                        if state.ttsBacklog > 0 {
                            Text(LF("queue %lld", state.ttsBacklog)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                            Button("Skip") { state.skipBacklog() }.controlSize(.mini)
                        }
                    }
                    LiveLevelMeter(meter: state.meter)
                }
            }
        }
        .padding(12)
    }

    private var phaseColor: Color {
        switch state.phase {
        case .idle: return .gray
        case .starting, .stopping: return .orange
        case .running: return .green
        }
    }

    private var phaseText: String {
        switch state.phase {
        case .idle: return L("Idle")
        case .starting: return L("Starting…")
        case .stopping: return L("Stopping…")
        case .running:
            if let speaking = state.nowSpeaking { return LF("Speaking: %@", speaking) }
            return LF("Listening to %@", state.selectedTarget?.name ?? L("app"))
        }
    }

    // MARK: Helpers

    private func statusRow<Trailing: View>(icon: String, tint: Color, text: String,
                                           @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack {
            Image(systemName: icon).foregroundStyle(tint)
            Text(text).font(.callout).foregroundStyle(.secondary)
            Spacer()
            trailing()
        }
    }

    private func permissionRow<Trailing: View>(_ title: String, granted: Bool,
                                               @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(granted ? .green : .red)
            Text(title)
            Spacer()
            if !granted { trailing() }
        }
    }
}

/// Simple horizontal audio level bar.
struct LevelMeter: View {
    var level: Float

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(level > 0.8 ? Color.red : level > 0.5 ? Color.yellow : Color.green)
                    .frame(width: geo.size.width * CGFloat(min(1, level)))
                    .animation(.linear(duration: 0.05), value: level)
            }
        }
        .frame(height: 6)
    }
}

extension Settings {
    /// Two-way binding into a `Settings` property for SwiftUI controls.
    func binding<T>(_ keyPath: ReferenceWritableKeyPath<Settings, T>) -> Binding<T> {
        Binding(get: { self[keyPath: keyPath] }, set: { self[keyPath: keyPath] = $0 })
    }
}
