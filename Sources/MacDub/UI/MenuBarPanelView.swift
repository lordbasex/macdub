import MacDubCore
import SwiftUI

/// The popover under the menu bar icon: status at a glance, the last lines, and the controls
/// you need without opening the main window.
struct MenuBarPanelView: View {
    @EnvironmentObject private var state: AppState
    var dismiss: () -> Void

    private var settings: Settings { state.settings }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            statusBlock
            preview
            quickControls
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 340)
    }

    private var header: some View {
        HStack(spacing: 10) {
            AppIconView(size: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text("MacDub").font(.headline)
                Text("Version \(Bundle.main.shortVersion)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                state.toggle()
            } label: {
                Label {
                    Text(state.phase == .running ? L("Stop") : L("Start"))
                } icon: {
                    Image(systemName: state.phase == .running ? "stop.fill" : "play.fill")
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(state.phase == .running ? .red : .accentColor)
            .disabled(state.isBusy || (state.phase == .idle && state.selectedTarget == nil))
        }
    }

    private var statusBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(state.phase == .running ? Color.green : Color.gray).frame(width: 7, height: 7)
                Text(statusText).font(.callout).lineLimit(1)
                Spacer()
                if state.latency.samples > 0 {
                    Text(LF("delay %.1f s", state.latency.spoken))
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            LiveLevelMeter(meter: state.meter)
        }
    }

    private var statusText: String {
        switch state.phase {
        case .idle: return state.selectedTarget.map { LF("Ready · %@", $0.name) } ?? L("Ready")
        case .starting: return L("Starting…")
        case .stopping: return L("Stopping…")
        case .running: return LF("Dubbing %@ · %@ → %@", state.selectedTarget?.name ?? "", settings.sourceLocaleID, settings.targetLanguageID)
        }
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 6) {
            let lines = state.segments.suffix(3)
            if lines.isEmpty && state.partialText.isEmpty {
                Text(state.phase == .running ? L("Listening…") : L("Subtitles will appear here."))
                    .font(.callout).foregroundStyle(.tertiary)
            }
            ForEach(lines) { segment in
                if settings.highlightSpokenWords, let translated = segment.translated, state.speaking?.segmentID == segment.id {
                    SpokenText(text: translated, word: state.speaking?.word, font: .callout)
                        .lineLimit(2)
                } else {
                    Text(segment.translated ?? segment.original)
                        .font(.callout)
                        .foregroundStyle(segment.translated == nil ? .secondary : .primary)
                        .lineLimit(2)
                }
            }
            if !state.partialText.isEmpty {
                Text(state.partialText).font(.caption).italic().foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private var quickControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Speak translation", isOn: settings.binding(\.speakTranslation))
            Toggle("Subtitle bar", isOn: Binding(
                get: { state.isSubtitleBarVisible },
                set: { _ in state.toggleSubtitleBar() }))
            if settings.usesProcessTap {
                HStack {
                    Image(systemName: "speaker.wave.1").foregroundStyle(.secondary)
                    Slider(value: settings.binding(\.originalVolume), in: 0...1)
                    Text("\(Int(settings.originalVolume * 100)) %").font(.caption).monospacedDigit().frame(width: 36, alignment: .trailing)
                }
                .help("Original audio level under the dub")
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
    }

    private var footer: some View {
        HStack {
            Button("Settings…") { dismiss(); state.showMainWindow() }
            Button("About") { dismiss(); state.showAbout() }
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
        }
        .controlSize(.small)
    }
}

/// The app icon as a view (falls back to a symbol if the icns is missing in a dev build).
struct AppIconView: View {
    var size: CGFloat

    var body: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
    }
}

extension Bundle {
    var shortVersion: String {
        (infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
    }
}
