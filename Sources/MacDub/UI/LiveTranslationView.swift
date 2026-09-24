import SwiftUI
import AVFAudio
import MacDubCore

/// Live translation: talk with someone in another language through a call app. What you say
/// reaches them translated, in your voice, through a virtual microphone; what they say reaches
/// you translated in your headphones.
struct LiveTranslationSectionView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var live: LiveTranslationController
    @ObservedObject var monitor: LiveMonitorServer
    private let palette = Theme.cyan
    @State private var draft = ""

    var body: some View {
        VStack(spacing: 0) {
            if live.phase == .running || live.phase == .stopping {
                conversation
            } else {
                setup
            }
            footer
        }
        .padding(.top, 34)
        .tint(palette.accent)
        .onAppear { live.refreshDevices(); live.refreshVoices() }
        // Back from Terminal (installer) or System Settings: look again.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            live.refreshDevices()
        }
    }

    // MARK: Setup

    private var setup: some View {
        ScrollView {
            HStack(alignment: .top, spacing: 36) {
                VStack(spacing: 18) {
                    HeroTile(symbol: "person.2.wave.2.fill", palette: palette, size: 230)
                    Text("Beta").font(.caption.weight(.semibold)).padding(.horizontal, 8).padding(.vertical, 3)
                        .background(palette.accent.opacity(0.25), in: Capsule()).foregroundStyle(.white)
                }
                .frame(width: 260)
                .padding(.top, 20)

                VStack(alignment: .leading, spacing: 18) {
                    Text("Live translation").font(.system(size: 40, weight: .semibold)).foregroundStyle(.white)
                    Text("Talk with people in another language through Meet, Zoom or any call app. What you say reaches them translated, in the voice you choose; what they say reaches your headphones in your language.")
                        .font(.title3).foregroundStyle(Theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)

                    if LiveTranslationController.isSupported {
                        if live.sendAudio && !live.virtualMicAvailable { virtualMicSetup }
                        settingsCard
                        checksCard
                    } else {
                        GlassCard(padding: 12) {
                            Label("Live translation needs macOS 26 or later: it listens to you and to the call at the same time with SpeechAnalyzer.",
                                  systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.white)
                        }
                    }
                    if let message = live.errorMessage {
                        GlassCard(padding: 12) {
                            Label(message, systemImage: "exclamationmark.octagon.fill")
                                .foregroundStyle(Color(red: 1, green: 0.55, blue: 0.55))
                        }
                    }
                }
                .frame(maxWidth: 580, alignment: .leading)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 24)
        }
    }

    private var settingsCard: some View {
        GlassCard {
            VStack(spacing: 10) {
                CardRow(title: "Call app", labelsControl: false) {
                    HStack(spacing: 6) {
                        Picker("", selection: $state.selectedTargetID) {
                            Text("Choose…").tag(String?.none)
                            ForEach(state.targets.filter { !$0.isSystem }) { t in Text(t.name).tag(Optional(t.id)) }
                        }
                        .labelsHidden().frame(maxWidth: 240)
                        .accessibilityLabel(Text("Call app"))
                        Button { Task { await state.refreshTargets() } } label: { Image(systemName: "arrow.clockwise") }
                            .buttonStyle(.borderless).foregroundStyle(Theme.secondaryText)
                            .iconButtonHelp("Refresh running applications")
                    }
                }
                CardRow(title: "Microphone", labelsControl: false) {
                    Picker("", selection: $live.micUID) {
                        Text(LF("System default (%@)", live.defaultMicName ?? "–")).tag("")
                        Divider()
                        ForEach(live.microphones) { mic in Text(mic.name).tag(mic.uid) }
                        // A saved microphone that is not connected right now.
                        if !live.micUID.isEmpty, !live.microphones.contains(where: { $0.uid == live.micUID }) {
                            Text("Not connected").tag(live.micUID)
                        }
                    }
                    .labelsHidden().frame(maxWidth: 280)
                    .accessibilityLabel(Text("Microphone"))
                }
                Divider().overlay(Theme.cardStroke)
                CardRow(title: "Your language") { languagePicker($live.myLocaleID) }
                CardRow(title: "Their language") { languagePicker($live.theirLocaleID) }
                Divider().overlay(Theme.cardStroke)
                CardRow(title: "Your voice for them", labelsControl: false) {
                    VoicePickerView(title: "", voices: live.voicesForThem, selection: $live.voiceForThemID)
                        .equatable().labelsHidden().frame(maxWidth: 280)
                        .accessibilityLabel(Text("Your voice for them"))
                }
                CardRow(title: "Their voice for you", labelsControl: false) {
                    VoicePickerView(title: "", voices: live.voicesForMe, selection: $live.voiceForMeID)
                        .equatable().labelsHidden().frame(maxWidth: 280)
                        .accessibilityLabel(Text("Their voice for you"))
                }
                CardRow(title: "Original audio") {
                    HStack {
                        Slider(value: $live.originalVolume, in: 0...1).frame(width: 180)
                        Text("\(Int(live.originalVolume * 100)) %").monospacedDigit().foregroundStyle(Theme.secondaryText).frame(width: 44, alignment: .trailing)
                    }
                }
                Divider().overlay(Theme.cardStroke)
                CardRow(title: "Send what I say as audio") { Toggle("", isOn: $live.sendAudio).labelsHidden() }
                CardRow(title: "Send what I say as chat text") { Toggle("", isOn: $live.sendChat).labelsHidden() }
                CardRow(title: "Translate their chat messages") { Toggle("", isOn: $live.translateChat).labelsHidden() }
                CardRow(title: "Read their chat messages aloud") { Toggle("", isOn: $live.speakChat).labelsHidden().disabled(!live.translateChat) }
            }
            .toggleStyle(.switch).controlSize(.small)
        }
    }

    /// BlackHole is missing: what it is, and one click to install it (Homebrew included).
    private var virtualMicSetup: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                Label("Install the virtual microphone", systemImage: "mic.badge.plus")
                    .font(.headline).foregroundStyle(.white)
                Text("For the call to hear your translated voice, MacDub uses BlackHole, a free, open-source virtual audio driver: in the call app you choose it as the microphone. It is installed separately and asks for your administrator password.")
                    .font(.callout).foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if VirtualMicInstaller.brewPath != nil {
                    HStack {
                        Button("Install BlackHole…") { VirtualMicInstaller.installBlackHole() }
                            .buttonStyle(.borderedProminent)
                        Text("brew install --cask blackhole-2ch").font(.caption.monospaced()).foregroundStyle(Theme.tertiaryText)
                    }
                } else {
                    Text("It is installed with Homebrew, which is not on this Mac yet.")
                        .font(.callout).foregroundStyle(Theme.secondaryText)
                    HStack {
                        Button("Install Homebrew and BlackHole…") { VirtualMicInstaller.installHomebrewAndBlackHole() }
                            .buttonStyle(.borderedProminent)
                        Button("What is Homebrew?") { NSWorkspace.shared.open(VirtualMicInstaller.homebrewURL) }
                    }
                }
                HStack {
                    Button("BlackHole's website") { NSWorkspace.shared.open(VirtualMicInstaller.blackHoleURL) }
                        .buttonStyle(.link)
                    Spacer()
                    Button("Check again") { live.refreshDevices() }.controlSize(.small)
                }
                Text("Only need the chat? Turn off “Send what I say as audio” below.")
                    .font(.caption).foregroundStyle(Theme.tertiaryText)
            }
        }
    }

    private var checksCard: some View {
        GlassCard(padding: 12) {
            VStack(alignment: .leading, spacing: 8) {
                if live.sendChat || live.translateChat {
                    check(false, ok: "", problem: L("The chat needs the MacDub extension for Meet in Chrome: chrome://extensions › Developer mode › Load unpacked › the extensions/meet-chat folder of MacDub."))
                        .foregroundStyle(Theme.secondaryText)
                }
                check(live.virtualMicAvailable || !live.sendAudio,
                      ok: LF("Virtual microphone: %@. In Meet on Chrome, the MacDub extension switches to it by itself; in other call apps, choose it as the microphone.", live.virtualMicName),
                      problem: LF("No virtual microphone (%@). Install it: brew install --cask blackhole-2ch, then restart the audio (sudo killall coreaudiod).", live.virtualMicName))
                check(!live.speakersInUse,
                      ok: L("Headphones in use."),
                      problem: L("Sound goes to the Mac's speakers: use headphones (AirPods, wired…), or your microphone will send their translated voice back to them."))
                HStack {
                    Spacer()
                    Button("Check again") { live.refreshDevices() }.controlSize(.small)
                }
            }
        }
    }

    private func check(_ ok: Bool, ok okText: String, problem: String) -> some View {
        Label(ok ? okText : problem, systemImage: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(ok ? Color.white : Color.orange)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// On this Mac first, then those whose model downloads when live translation starts; 👤 where
    /// your Personal Voice speaks the language.
    private func languagePicker(_ selection: Binding<String>) -> some View {
        Picker("", selection: selection) {
            let here = live.languages.filter(\.installed)
            ForEach(here) { option in Text(title(option)).tag(option.id) }
            if !here.isEmpty { Divider() }
            ForEach(live.languages.filter { !$0.installed }) { option in
                Text(title(option) + "  · " + L("downloads when it starts")).tag(option.id)
            }
        }
        .labelsHidden().frame(maxWidth: 320)
    }

    private func title(_ option: LiveTranslationController.LanguageOption) -> String {
        (option.personalVoice ? "👤 " : "") + option.name
    }

    // MARK: Running

    private var conversation: some View {
        VStack(spacing: 12) {
            HStack(spacing: 14) {
                Circle().fill(Color.green).frame(width: 9, height: 9).shadow(color: .green, radius: 6)
                VStack(alignment: .leading, spacing: 2) {
                    Text(LF("Translating with %@", state.selectedTarget?.name ?? L("app"))).font(.headline).foregroundStyle(.white)
                    Text("\(live.myLocaleID) ↔ \(live.theirLocaleID) · \(live.virtualMicName)")
                        .font(.caption).foregroundStyle(Theme.tertiaryText)
                }
                Spacer()
                if live.sendChat || live.translateChat {
                    Label(live.chatConnected ? L("Meet chat connected") : L("Meet chat: waiting for the extension"),
                          systemImage: live.chatConnected ? "bubble.left.and.bubble.right.fill" : "bubble.left.and.bubble.right")
                        .font(.caption).foregroundStyle(live.chatConnected ? palette.accent : Theme.tertiaryText)
                }
                if let url = monitor.url {
                    Link(url.absoluteString, destination: url).font(.caption).foregroundStyle(palette.accent)
                }
            }
            .padding(.horizontal, 28)

            HStack(alignment: .top, spacing: 14) {
                column(side: .me, title: "You", level: live.micLevel)
                column(side: .them, title: "Them", level: live.callLevel)
            }
            .padding(.horizontal, 28)

            // Typed in your language, sent translated to the call's chat.
            HStack(spacing: 8) {
                TextField("Write a message to translate and send to the chat…", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(sendDraft)
                Button("Send", action: sendDraft).disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 28)
        }
    }

    private func column(side: LiveTranslationController.Side, title: LocalizedStringKey, level: Float) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.headline).foregroundStyle(.white)
                Text(side == .me ? "\(live.myLocaleID) → \(live.theirLocaleID)" : "\(live.theirLocaleID) → \(live.myLocaleID)")
                    .font(.caption).foregroundStyle(Theme.tertiaryText)
                Spacer()
                LevelMeter(level: level).frame(width: 90)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(live.lines.filter { $0.side == side }) { line in
                            bubble(line, side: side).id(line.id)
                        }
                        if live.speaking.contains(side) || !(live.partial[side] ?? "").isEmpty {
                            TypingBubble(text: live.partial[side] ?? "", tint: side == .me ? palette.accent : .white)
                                .id("typing-\(side.rawValue)")
                        }
                    }
                    .padding(14)
                }
                .onChange(of: live.lines.count) { scrollToEnd(proxy, side) }
                .onChange(of: live.partial[side] ?? "") { scrollToEnd(proxy, side) }
            }
            .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(side == .me ? palette.accent.opacity(0.5) : Theme.cardStroke))
        }
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy, _ side: LiveTranslationController.Side) {
        withAnimation {
            if live.speaking.contains(side) || !(live.partial[side] ?? "").isEmpty {
                proxy.scrollTo("typing-\(side.rawValue)", anchor: .bottom)
            } else if let last = live.lines.last(where: { $0.side == side }) {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }

    /// One sentence: the original, its translation and how long each step took.
    private func bubble(_ line: LiveTranslationController.Line, side: LiveTranslationController.Side) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                if line.via != .voice {
                    Image(systemName: line.via == .chat ? "bubble.left.fill" : "keyboard")
                        .font(.caption2).foregroundStyle(palette.accent)
                }
                if let author = line.author { Text(author).font(.caption.weight(.semibold)).foregroundStyle(palette.accent) }
                Text(line.original).font(.callout).foregroundStyle(Theme.secondaryText)
            }
            Text(line.translated ?? (line.failed ? L("(not translated)") : "…"))
                .font(.title3).foregroundStyle(.white)
            timings(line)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background((side == .me ? palette.accent.opacity(0.18) : Color.white.opacity(0.08)),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Transcription · audio · total, with the translation step in the tooltip.
    @ViewBuilder
    private func timings(_ line: LiveTranslationController.Line) -> some View {
        let parts = [
            line.transcription.map { LF("Transcription %.1f s", $0) },
            line.audio.map { LF("Audio %.1f s", $0) },
            line.total.map { LF("Total %.1f s", $0) },
        ].compactMap { $0 }
        if !parts.isEmpty {
            Text(parts.joined(separator: "  ·  "))
                .font(.caption2).monospacedDigit().foregroundStyle(Theme.tertiaryText)
                .help(LF("End of the sentence → text %.2f s · text → translation %.2f s · translation → voice %.2f s",
                         line.transcription ?? 0, line.translation ?? 0, max(0, (line.audio ?? 0) - (line.translation ?? 0))))
        }
    }

    private func sendDraft() {
        live.type(draft)
        draft = ""
    }

    // MARK: Footer

    private var footer: some View {
        HStack(alignment: .center, spacing: 28) {
            Spacer()
            secondaryButton(monitor.url == nil ? "Open monitor" : "Monitor", symbol: "safari") { state.openLiveMonitor() }
            RoundActionButton(
                title: live.phase == .running ? "Stop" : "Start",
                symbol: live.phase == .running ? "stop.fill" : "play.fill",
                palette: palette,
                destructive: live.phase == .running,
                busy: live.phase == .starting || live.phase == .stopping,
                enabled: LiveTranslationController.isSupported && state.phase == .idle
                    && (live.phase == .running || (live.phase == .idle && state.selectedTarget != nil))
            ) { state.toggleLiveTranslation() }
            secondaryButton("Clear", symbol: "trash") { live.clear() }
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
            .frame(width: 110)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(title))
    }
}

/// "Someone is talking": animated dots and the words recognized so far, like a chat app's
/// typing indicator.
private struct TypingBubble: View {
    let text: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TimelineView(.periodic(from: .now, by: 0.35)) { context in
                let step = Int(context.date.timeIntervalSinceReferenceDate / 0.35) % 3
                HStack(spacing: 5) {
                    ForEach(0..<3) { i in
                        Circle().fill(tint.opacity(i == step ? 0.95 : 0.35)).frame(width: 7, height: 7)
                    }
                }
            }
            if !text.isEmpty {
                Text(text).font(.callout).italic().foregroundStyle(Theme.secondaryText)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityLabel(Text("Speaking…"))
    }
}
