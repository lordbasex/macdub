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
            }
        }
    }

    private var checksCard: some View {
        GlassCard(padding: 12) {
            VStack(alignment: .leading, spacing: 8) {
                check(live.virtualMicAvailable,
                      ok: LF("Virtual microphone: %@. In the call app, choose it as the microphone.", live.virtualMicName),
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

    private func languagePicker(_ selection: Binding<String>) -> some View {
        Picker("", selection: selection) {
            ForEach(state.sourceLocales, id: \.identifier) { locale in
                Text(SpeechAndTranslationManager.displayName(locale)).tag(locale.identifier)
            }
        }
        .labelsHidden().frame(maxWidth: 280)
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
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(live.lines.filter { $0.side == side }) { line in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(line.original).font(.callout).foregroundStyle(Theme.secondaryText)
                                Text(line.translated ?? (line.failed ? L("(not translated)") : "…"))
                                    .font(.title3).foregroundStyle(.white)
                                if let spoken = line.spokenAt {
                                    Text(LF("voice after %.1f s", spoken.timeIntervalSince(line.recognizedAt)))
                                        .font(.caption2).monospacedDigit().foregroundStyle(Theme.tertiaryText)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(line.id)
                        }
                    }
                    .padding(14)
                }
                .onChange(of: live.lines.count) {
                    if let last = live.lines.last(where: { $0.side == side }) {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
            .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(side == .me ? palette.accent.opacity(0.5) : Theme.cardStroke))
        }
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
