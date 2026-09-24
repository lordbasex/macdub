import SwiftUI
import MacDubCore

/// The main window: sidebar on the left, a section "hero" on the right, all over a gradient
/// that follows the selected section, with the round Start/Stop button at the bottom.
struct MainView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    private var palette: Theme.Palette { state.section.palette }

    var body: some View {
        ZStack {
            palette.gradient.ignoresSafeArea()
                .animation(.easeInOut(duration: 0.45), value: state.section)
            // Soft light in the top-left, like a spotlight on the hero.
            RadialGradient(colors: [.white.opacity(0.12), .clear], center: .init(x: 0.35, y: 0.25), startRadius: 0, endRadius: 520)
                .ignoresSafeArea()

            HStack(spacing: 0) {
                sidebar
                    .frame(width: 224)
                Divider().overlay(Color.white.opacity(0.08))
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .preferredColorScheme(.dark)
        .background(TranslationHostView(bridge: state.translation))
        .onAppear {
            state.openWindowAction = openWindow
            state.dismissWindowAction = dismissWindow
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            Spacer().frame(height: 34) // room for the traffic lights
            ForEach(AppSection.allCases) { section in
                SidebarRow(section: section, selected: state.section == section) {
                    withAnimation(.easeInOut(duration: 0.25)) { state.section = section }
                }
            }
            Spacer()
            SettingsLink {
                HStack(spacing: 12) {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.8))
                        .frame(width: 24)
                    Text("Settings").font(.system(size: 14)).foregroundStyle(.white)
                    Spacer()
                    Text("⌘,").font(.caption).foregroundStyle(Theme.tertiaryText)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Settings"))
            HStack(spacing: 8) {
                AppIconView(size: 22)
                Text("MacDub \(Bundle.main.shortVersion)").font(.caption).foregroundStyle(Theme.tertiaryText)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 14)
        }
        .padding(.horizontal, 12)
    }

    @ViewBuilder
    private var detail: some View {
        switch state.section {
        case .dub: DubSectionView()
        case .live: LiveTranslationSectionView(live: state.live, monitor: state.liveMonitor)
        case .subtitles: SubtitlesSectionView()
        case .history: HistorySectionView()
        case .ai: AISectionView()
        }
    }
}

// MARK: - Dubbing (home)

struct DubSectionView: View {
    @EnvironmentObject private var state: AppState
    private var settings: Settings { state.settings }
    private let palette = Theme.violet

    var body: some View {
        VStack(spacing: 0) {
            if state.phase == .running || state.phase == .stopping {
                liveView
            } else {
                heroView
            }
            footer
        }
        .padding(.top, 34)
    }

    // Idle: hero + session card.
    private var heroView: some View {
        ScrollView {
            HStack(alignment: .top, spacing: 36) {
                VStack(spacing: 18) {
                    HeroTile(image: NSApp.applicationIconImage, palette: palette, size: 230)
                    HStack(spacing: 6) {
                        Circle().fill(state.capabilities.screenRecording ? Color.green : Color.orange).frame(width: 7, height: 7)
                        Text(state.capabilities.screenRecording ? "Ready to capture" : "Screen Recording permission needed")
                            .font(.caption).foregroundStyle(Theme.secondaryText)
                    }
                }
                .frame(width: 260)
                .padding(.top, 20)

                VStack(alignment: .leading, spacing: 18) {
                    Text("Dubbing").font(.system(size: 40, weight: .semibold)).foregroundStyle(.white)
                    Text("Pick what to listen to, the languages and a voice. MacDub captures the app's audio, translates it on your Mac and speaks it over the original.")
                        .font(.title3).foregroundStyle(Theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)

                    sessionCard

                    if !state.capabilities.screenRecording || state.capabilities.speechAuthorization != .authorized {
                        permissionsCard
                    }
                    if let message = state.errorMessage {
                        GlassCard(padding: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Label(message, systemImage: "exclamationmark.octagon.fill").foregroundStyle(Color(red: 1, green: 0.5, blue: 0.5))
                                if let s = state.errorSuggestion { Text(s).font(.caption).foregroundStyle(Theme.secondaryText) }
                            }
                        }
                        .onTapGesture { state.clearError() }
                    }
                    if let notice = state.notice {
                        Label(notice, systemImage: "info.circle").font(.caption).foregroundStyle(Theme.secondaryText)
                    }
                }
                .frame(maxWidth: 560, alignment: .leading)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 24)
        }
    }

    private var sessionCard: some View {
        GlassCard {
            VStack(spacing: 10) {
                CardRow(title: "Application", labelsControl: false) {
                    HStack(spacing: 6) {
                        Picker("", selection: $state.selectedTargetID) {
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
                        .labelsHidden().frame(maxWidth: 240)
                        .accessibilityLabel(Text("Application"))
                        Button { Task { await state.refreshTargets() } } label: { Image(systemName: "arrow.clockwise") }
                            .buttonStyle(.borderless).foregroundStyle(Theme.secondaryText)
                            .iconButtonHelp("Refresh running applications")
                    }
                }
                Divider().overlay(Theme.cardStroke)
                CardRow(title: "Spoken language") {
                    Picker("", selection: settings.binding(\.sourceLocaleID)) {
                        ForEach(state.sourceLocales, id: \.identifier) { locale in
                            let onDevice = SpeechAndTranslationManager.supportsOnDevice(locale)
                            Text(SpeechAndTranslationManager.displayName(locale) + (onDevice ? "" : "  · " + L("needs download")))
                                .tag(locale.identifier)
                        }
                    }
                    .labelsHidden().frame(maxWidth: 280)
                }
                if !state.capabilities.sourceOnDevice {
                    hint("No on-device model for this language. Add it under Keyboard › Dictation.", action: "Open Dictation Settings") {
                        SystemSettings.open(SystemSettings.dictation)
                    }
                }
                CardRow(title: "Translate to") {
                    Picker("", selection: settings.binding(\.targetLanguageID)) {
                        ForEach(state.targetLanguages, id: \.minimalIdentifier) { lang in
                            Text(TranslationCatalog.displayName(lang)).tag(lang.minimalIdentifier)
                        }
                    }
                    .labelsHidden().frame(maxWidth: 280)
                }
                if state.capabilities.translationStatus == .supported {
                    hint("Model not downloaded yet (one-time download).", action: "Prepare translation") { state.prepareTranslation() }
                } else if state.capabilities.translationStatus == .unsupported {
                    hint("This language pair is not supported.", action: nil) {}
                }
                Divider().overlay(Theme.cardStroke)
                CardRow(title: "Voice", labelsControl: false) {
                    HStack(spacing: 6) {
                        VoicePickerView(title: "", voices: state.voices, selection: settings.binding(\.voiceIdentifier))
                            .equatable().labelsHidden().frame(maxWidth: 280)
                            .accessibilityLabel(Text("Voice"))
                        Button { state.testVoice() } label: { Image(systemName: "play.circle") }
                            .buttonStyle(.borderless).foregroundStyle(Theme.secondaryText).iconButtonHelp("Test voice")
                        Button { state.reloadVoices() } label: { Image(systemName: "arrow.clockwise") }
                            .buttonStyle(.borderless).foregroundStyle(Theme.secondaryText).iconButtonHelp("Reload the voice list after downloading voices in System Settings")
                    }
                }
                if settings.usesProcessTap {
                    CardRow(title: "Original audio") {
                        HStack {
                            Slider(value: settings.binding(\.originalVolume), in: 0...1).frame(width: 180)
                                .accessibilityLabel(Text("Original audio"))
                            Text("\(Int(settings.originalVolume * 100)) %").monospacedDigit().foregroundStyle(Theme.secondaryText).frame(width: 44, alignment: .trailing)
                        }
                    }
                }
                CardRow(title: "Speak the translation") {
                    Toggle("", isOn: settings.binding(\.speakTranslation)).labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
            }
        }
    }

    private var permissionsCard: some View {
        GlassCard(padding: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Permissions").font(.headline).foregroundStyle(.white)
                permissionRow("Screen & System Audio Recording", granted: state.capabilities.screenRecording) {
                    Button("Request") { state.requestScreenRecording() }
                }
                permissionRow("Speech Recognition", granted: state.capabilities.speechAuthorization == .authorized) {
                    if state.capabilities.speechAuthorization == .notDetermined {
                        Button("Request") { state.requestSpeechAuthorization() }
                    } else {
                        Button("Open Settings") { SystemSettings.open(SystemSettings.speechRecognition) }
                    }
                }
                if !state.capabilities.screenRecording {
                    Text("After enabling Screen Recording, quit and relaunch MacDub.").font(.caption).foregroundStyle(Theme.tertiaryText)
                }
            }
        }
    }

    private func permissionRow<T: View>(_ title: LocalizedStringKey, granted: Bool, @ViewBuilder trailing: () -> T) -> some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle.fill").foregroundStyle(granted ? .green : .red)
            Text(title).foregroundStyle(.white)
            Spacer()
            if !granted { trailing().controlSize(.small) }
        }
    }

    private func hint(_ text: LocalizedStringKey, action: LocalizedStringKey?, perform: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(text).font(.caption).foregroundStyle(Theme.secondaryText)
            Spacer()
            if let action { Button(action, action: perform).controlSize(.small) }
        }
    }

    // Running: live transcript.
    private var liveView: some View {
        VStack(spacing: 12) {
            HStack(spacing: 14) {
                Circle().fill(Color.green).frame(width: 9, height: 9)
                    .shadow(color: .green, radius: 6)
                VStack(alignment: .leading, spacing: 2) {
                    Text(LF("Listening to %@", state.selectedTarget?.name ?? L("app"))).font(.headline).foregroundStyle(.white)
                    Text("\(settings.sourceLocaleID) → \(settings.targetLanguageID) · \(state.activeEngine ?? "-") / \(state.activeRecognitionEngine ?? "-")")
                        .font(.caption).foregroundStyle(Theme.tertiaryText)
                }
                Spacer()
                if state.latency.samples > 0 {
                    Text(LF("delay %.1f s · avg %.1f s · translate %.1f s",
                            state.latency.lastSpoken, state.latency.spoken, state.latency.translation))
                        .font(.caption).monospacedDigit().foregroundStyle(Theme.secondaryText)
                }
                if state.ttsBacklog > 0 {
                    Text(LF("queue %lld", state.ttsBacklog)).font(.caption).monospacedDigit().foregroundStyle(Theme.secondaryText)
                    Button("Skip") { state.skipBacklog() }.controlSize(.mini)
                }
                LiveLevelMeter(meter: state.meter).frame(width: 120)
            }
            .padding(.horizontal, 28)

            if let notice = state.notice {
                Label(notice, systemImage: "info.circle").font(.caption).foregroundStyle(Theme.secondaryText)
            }

            SubtitlesView()
                .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.cardStroke))
                .padding(.horizontal, 28)
        }
    }

    private var footer: some View {
        HStack(alignment: .center, spacing: 28) {
            Spacer()
            if state.phase == .running {
                secondaryButton(state.isSubtitleBarVisible ? "Hide subtitle bar" : "Show subtitle bar",
                                symbol: "rectangle.bottomthird.inset.filled") { state.toggleSubtitleBar() }
            }
            RoundActionButton(
                title: state.phase == .running ? "Stop" : "Start",
                symbol: state.phase == .running ? "stop.fill" : "play.fill",
                palette: palette,
                destructive: state.phase == .running,
                busy: state.isBusy,
                enabled: !state.isBusy && (state.phase == .running || state.selectedTarget != nil)
            ) { state.toggle() }
            if state.phase == .running {
                secondaryButton("Clear", symbol: "trash") { state.clearTranscript() }
            }
            Spacer()
        }
        .padding(.vertical, 22)
    }

    private func secondaryButton(_ title: LocalizedStringKey, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 16, weight: .semibold))
                Text(title).font(.caption)
            }
            .foregroundStyle(.white.opacity(0.85))
            .frame(width: 96)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(title))
    }
}

// MARK: - Subtitles section

struct SubtitlesSectionView: View {
    @EnvironmentObject private var state: AppState
    private var settings: Settings { state.settings }
    private let palette = Theme.magenta

    var body: some View {
        ScrollView {
            HStack(alignment: .top, spacing: 36) {
                HeroTile(symbol: "captions.bubble.fill", palette: palette, size: 230).padding(.top, 20)
                    .frame(width: 260)
                VStack(alignment: .leading, spacing: 18) {
                    Text("Subtitles").font(.system(size: 40, weight: .semibold)).foregroundStyle(.white)
                    Text("Read along while MacDub speaks: a transcript panel while dubbing, and a floating bar you can drop over any video.")
                        .font(.title3).foregroundStyle(Theme.secondaryText).fixedSize(horizontal: false, vertical: true)
                    VStack(alignment: .leading, spacing: 12) {
                        FeatureRow(symbol: "text.word.spacing", text: "Karaoke highlighting of the words being spoken", palette: palette)
                        FeatureRow(symbol: "rectangle.bottomthird.inset.filled", text: "Floating subtitle bar, always on top (⌘B)", palette: palette)
                        FeatureRow(symbol: "square.and.arrow.up", text: "Export as .srt, .md or .txt", palette: palette)
                    }
                    GlassCard {
                        VStack(alignment: .leading, spacing: 10) {
                            CardRow(title: "Include original text") { Toggle("", isOn: settings.binding(\.showOriginalInSubtitles)).labelsHidden() }
                            CardRow(title: "Highlight the words being spoken") { Toggle("", isOn: settings.binding(\.highlightSpokenWords)).labelsHidden() }
                            CardRow(title: "Auto-scroll") { Toggle("", isOn: settings.binding(\.autoScrollSubtitles)).labelsHidden() }
                            Divider().overlay(Theme.cardStroke)
                            CardRow(title: "Bar lines") {
                                Stepper("\(settings.pillLines)", value: settings.binding(\.pillLines), in: 1...6).foregroundStyle(.white)
                            }
                            CardRow(title: "Bar width") { Slider(value: settings.binding(\.pillWidth), in: 520...1400, step: 20).frame(width: 220) }
                            CardRow(title: "Bar text size") { Slider(value: settings.binding(\.pillFontSize), in: 14...34, step: 1).frame(width: 220) }
                        }
                        .toggleStyle(.switch).controlSize(.small).foregroundStyle(.white)
                    }
                    HStack {
                        Button(state.isSubtitleBarVisible ? "Hide subtitle bar" : "Show subtitle bar") { state.toggleSubtitleBar() }
                        Menu("Export…") {
                            Button("Subtitles (.srt) — translation") { state.exportTranscript(format: .srt, content: .translated) }
                            Button("Subtitles (.srt) — both") { state.exportTranscript(format: .srt, content: .both) }
                            Button("Markdown (.md) — for AI summaries") { state.exportTranscript(format: .md, content: .both) }
                            Button("Text (.txt) — both") { state.exportTranscript(format: .txt, content: .both) }
                        }
                        .fixedSize().disabled(state.segments.isEmpty)
                    }
                }
                .frame(maxWidth: 560, alignment: .leading)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 40).padding(.top, 34).padding(.bottom, 30)
        }
    }
}

// MARK: - AI section

struct AISectionView: View {
    private let palette = Theme.azure

    var body: some View {
        ScrollView {
            HStack(alignment: .top, spacing: 36) {
                HeroTile(symbol: "sparkles", palette: palette, size: 230).padding(.top, 20)
                    .frame(width: 260)
                VStack(alignment: .leading, spacing: 18) {
                    Text("AI & MCP").font(.system(size: 40, weight: .semibold)).foregroundStyle(.white)
                    Text("Summarise what was said with the assistant you already have, and let Claude Code, Claude Desktop, Codex or any MCP client read the live transcript.")
                        .font(.title3).foregroundStyle(Theme.secondaryText).fixedSize(horizontal: false, vertical: true)
                    VStack(alignment: .leading, spacing: 12) {
                        FeatureRow(symbol: "text.badge.checkmark", text: "Summaries with Claude Code, Codex, Ollama, LM Studio or Apple Intelligence", palette: palette)
                        FeatureRow(symbol: "point.3.connected.trianglepath.dotted", text: "MCP server: 18 tools, live resources, prompts", palette: palette)
                        FeatureRow(symbol: "lock.shield", text: "Everything stays on this Mac", palette: palette)
                    }
                    Form { AIIntegrationSection() }
                        .formStyle(.grouped)
                        .scrollContentBackground(.hidden)
                        .scrollDisabled(true)
                        .frame(minHeight: 340)
                        .padding(.horizontal, -20) // grouped forms add their own inset; align with the text above
                }
                .frame(maxWidth: 640, alignment: .leading)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 40).padding(.top, 34).padding(.bottom, 30)
        }
    }
}
