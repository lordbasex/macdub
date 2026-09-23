import MacDubCore
import SwiftUI

/// The always-on-top subtitle pill: the last translated sentences in large type (the one being
/// spoken highlighted word by word), the live partial underneath, and the controls you need
/// while watching — Stop/Start, quick settings, hide. Lives in a `.plain` window so only the
/// pill is visible; drag it by the grip on the left or anywhere on its background.
struct FloatingSubtitlesView: View {
    static let windowID = "floating-subtitles"

    @EnvironmentObject private var state: AppState
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var showQuickSettings = false

    private var settings: Settings { state.settings }

    private var lines: [Segment] {
        Array(state.segments.filter { $0.translated != nil }.suffix(settings.pillLines))
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            // Grip: an explicit drag handle, since text and buttons don't start a window drag.
            VStack(spacing: 6) {
                AppIconView(size: 30)
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.45))
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .gesture(WindowDragGesture())
            .help("Drag to move")

            VStack(alignment: .leading, spacing: 4) {
                if lines.isEmpty {
                    Text(state.phase == .running ? L("Listening…") : L("MacDub — press ▶ to start dubbing"))
                        .font(.system(size: settings.pillFontSize))
                        .foregroundStyle(.white.opacity(0.55))
                }
                ForEach(Array(lines.enumerated()), id: \.element.id) { index, segment in
                    let isLast = index == lines.count - 1
                    let speaking = state.speaking?.segmentID == segment.id ? state.speaking : nil
                    if settings.highlightSpokenWords, speaking != nil {
                        SpokenText(text: segment.translated ?? "", word: speaking?.word,
                                   baseColor: .white, spokenColor: .yellow, currentColor: .yellow,
                                   font: .system(size: settings.pillFontSize, weight: .semibold))
                            .lineLimit(2)
                    } else {
                        Text(segment.translated ?? "")
                            .font(.system(size: settings.pillFontSize, weight: isLast ? .semibold : .regular))
                            .foregroundStyle(.white.opacity(isLast ? 1 : 0.6))
                            .lineLimit(2)
                    }
                }
                if settings.showOriginalInSubtitles, !state.partialText.isEmpty {
                    Text(state.partialText)
                        .font(.system(size: max(11, settings.pillFontSize * 0.6)))
                        .foregroundStyle(.white.opacity(0.45))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .gesture(WindowDragGesture())
            .animation(.easeOut(duration: 0.15), value: lines)

            HStack(spacing: 6) {
                if state.ttsBacklog > 1 {
                    Text("\(state.ttsBacklog)")
                        .font(.caption2).monospacedDigit()
                        .foregroundStyle(.white.opacity(0.6))
                        .help("Sentences waiting to be spoken")
                }
                pillButton(state.phase == .running ? "stop.circle.fill" : "play.circle.fill",
                           tint: state.phase == .running ? .red : .green,
                           help: state.phase == .running ? L("Stop dubbing") : L("Start dubbing")) {
                    state.toggle()
                }
                .disabled(state.isBusy || (state.phase == .idle && state.selectedTarget == nil))

                pillButton("slider.horizontal.3", tint: .white, help: L("Quick settings")) {
                    showQuickSettings.toggle()
                }
                .popover(isPresented: $showQuickSettings, arrowEdge: .top) {
                    QuickSettingsView().environmentObject(state)
                }

                pillButton("xmark.circle.fill", tint: .white.opacity(0.7),
                           help: L("Hide subtitle bar (menu bar icon brings it back)")) {
                    dismissWindow(id: Self.windowID)
                }
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .padding(.vertical, 12)
        .frame(width: settings.pillWidth)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color.black.opacity(0.78))
                .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(.white.opacity(0.14)))
                .shadow(color: .black.opacity(0.45), radius: 18, y: 6)
        )
        .padding(24) // room for the shadow inside the borderless window
        .onAppear { state.isSubtitleBarVisible = true }
        .onDisappear { state.isSubtitleBarVisible = false }
    }

    private func pillButton(_ symbol: String, tint: Color, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 22))
                .foregroundStyle(tint)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Minimal controls reachable from the pill without opening the main window.
struct QuickSettingsView: View {
    @EnvironmentObject private var state: AppState

    private var settings: Settings { state.settings }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Speak translation", isOn: settings.binding(\.speakTranslation))
            Toggle("Show original text", isOn: settings.binding(\.showOriginalInSubtitles))
            Toggle("Highlight spoken words", isOn: settings.binding(\.highlightSpokenWords))

            if settings.usesProcessTap {
                LabeledContent("Original audio") {
                    HStack {
                        Slider(value: settings.binding(\.originalVolume), in: 0...1)
                        Text("\(Int(settings.originalVolume * 100)) %").monospacedDigit().frame(width: 36, alignment: .trailing)
                    }
                }
                Toggle("Only lower while speaking", isOn: settings.binding(\.duckOnlyWhileSpeaking))
            }

            LabeledContent("Rate") {
                Slider(value: settings.binding(\.speechRate), in: 0.3...0.75)
            }
            LabeledContent("Voice") {
                VoicePickerView(title: "", voices: state.voices, selection: settings.binding(\.voiceIdentifier))
                    .equatable()
                    .labelsHidden()
            }
            LabeledContent("Max delay") {
                HStack {
                    Slider(value: settings.binding(\.maxSpokenLag), in: 2...15, step: 0.5)
                    Text(String(format: "%.1f s", locale: .current, settings.maxSpokenLag)).monospacedDigit().frame(width: 40)
                }
            }

            Divider()
            Stepper("Lines: \(settings.pillLines)", value: settings.binding(\.pillLines), in: 1...6)
            LabeledContent("Width") {
                Slider(value: settings.binding(\.pillWidth), in: 520...1400, step: 20)
            }
            LabeledContent("Text size") {
                Slider(value: settings.binding(\.pillFontSize), in: 14...34, step: 1)
            }

            Divider()
            HStack {
                Button("Skip backlog") { state.skipBacklog() }.disabled(state.ttsBacklog < 2)
                Spacer()
                Button("Open MacDub…") { state.showMainWindow() }
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .padding(14)
        .frame(width: 340)
    }
}
