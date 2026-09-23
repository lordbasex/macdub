import MacDubCore
import SwiftUI

/// The popover under the menu bar icon: status at a glance in tiles, the last lines, and the
/// controls you need without opening the main window.
struct MenuBarPanelView: View {
    @EnvironmentObject private var state: AppState
    var dismiss: () -> Void

    private var settings: Settings { state.settings }
    private var running: Bool { state.phase == .running }
    private var palette: Theme.Palette { running ? Theme.emerald : Theme.violet }

    var body: some View {
        ZStack {
            palette.gradient
            VStack(spacing: 12) {
                header
                HStack(spacing: 10) {
                    tile("Latency", value: state.latency.samples > 0 ? String(format: "%.1f s", locale: .current, state.latency.spoken) : "—",
                         detail: state.latency.samples > 0 ? LF("translate %.1f s", state.latency.translation) : L("no data yet"), symbol: "timer")
                    tile("Voice", value: state.voices.first { $0.identifier == settings.voiceIdentifier }?.name ?? "—",
                         detail: settings.speakTranslation ? L("speaking") : L("muted"), symbol: "speaker.wave.2.fill")
                }
                HStack(spacing: 10) {
                    tile("Languages", value: "\(settings.sourceLocaleID) → \(settings.targetLanguageID)",
                         detail: state.capabilities.translationStatus == .installed ? L("model ready") : L("model needed"), symbol: "globe")
                    tile("Original audio", value: settings.usesProcessTap ? "\(Int(settings.originalVolume * 100)) %" : "100 %",
                         detail: settings.usesProcessTap ? L("in the background") : L("ScreenCaptureKit"), symbol: "waveform")
                }
                preview
                quickControls
                bottomBar
            }
            .padding(14)
        }
        .frame(width: 380)
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("MacDub").font(.title2.weight(.semibold)).foregroundStyle(.white)
                    Text(statusWord).font(.title2.weight(.semibold)).foregroundStyle(palette.accent)
                }
                Text(statusLine).font(.caption).foregroundStyle(Theme.secondaryText).lineLimit(1)
                LiveLevelMeter(meter: state.meter).frame(width: 150)
            }
            Spacer()
            AppIconView(size: 52)
        }
    }

    private var statusWord: String {
        switch state.phase {
        case .idle: return L("Idle")
        case .starting: return L("Starting…")
        case .stopping: return L("Stopping…")
        case .running: return L("Dubbing")
        }
    }

    private var statusLine: String {
        if let t = state.selectedTarget {
            return running ? LF("Listening to %@", t.name) : LF("Ready · %@", t.name)
        }
        return L("Ready")
    }

    private func tile(_ title: LocalizedStringKey, value: String, detail: String, symbol: String) -> some View {
        GlassCard(padding: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: symbol).font(.caption).foregroundStyle(palette.accent)
                    Text(title).font(.caption).foregroundStyle(Theme.secondaryText)
                }
                Text(value).font(.headline).foregroundStyle(.white).lineLimit(1)
                Text(detail).font(.caption2).foregroundStyle(Theme.tertiaryText).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var preview: some View {
        GlassCard(padding: 12) {
            VStack(alignment: .leading, spacing: 6) {
                let lines = state.segments.suffix(3)
                if lines.isEmpty && state.partialText.isEmpty {
                    Text(running ? L("Listening…") : L("Subtitles will appear here."))
                        .font(.callout).foregroundStyle(Theme.tertiaryText)
                }
                ForEach(lines) { segment in
                    if settings.highlightSpokenWords, let translated = segment.translated, state.speaking?.segmentID == segment.id {
                        SpokenText(text: translated, word: state.speaking?.word, baseColor: .white, spokenColor: palette.accent,
                                   currentColor: palette.accent, font: .callout).lineLimit(2)
                    } else {
                        Text(segment.translated ?? segment.original).font(.callout)
                            .foregroundStyle(segment.translated == nil ? Theme.secondaryText : .white).lineLimit(2)
                    }
                }
                if !state.partialText.isEmpty {
                    Text(state.partialText).font(.caption).italic().foregroundStyle(Theme.tertiaryText).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var quickControls: some View {
        HStack(spacing: 10) {
            Button { state.toggle() } label: {
                Label(running ? "Stop" : "Start", systemImage: running ? "stop.fill" : "play.fill")
                    .font(.headline).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).padding(.vertical, 9)
                    .background(running ? Color.red.opacity(0.85) : palette.accent.opacity(0.9), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(state.isBusy || (state.phase == .idle && state.selectedTarget == nil))
            iconToggle("captions.bubble.fill", on: state.isSubtitleBarVisible, help: "Subtitle bar") { state.toggleSubtitleBar() }
            iconToggle(settings.speakTranslation ? "speaker.wave.2.fill" : "speaker.slash.fill", on: settings.speakTranslation, help: "Speak translation") {
                settings.speakTranslation.toggle()
            }
        }
    }

    private func iconToggle(_ symbol: String, on: Bool, help: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(on ? .white : Theme.secondaryText)
                .frame(width: 40, height: 36)
                .background(on ? palette.accent.opacity(0.6) : Theme.cardFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var bottomBar: some View {
        HStack {
            Button { dismiss(); state.showHistory() } label: { Image(systemName: "clock.arrow.circlepath") }
                .buttonStyle(.plain).foregroundStyle(Theme.secondaryText).iconButtonHelp("Session History…")
            Spacer()
            Button { dismiss(); state.showMainWindow() } label: {
                Text("Open MacDub").font(.subheadline.weight(.medium)).foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            Spacer()
            Button { dismiss(); state.showSettings() } label: { Image(systemName: "gearshape.fill") }
                .buttonStyle(.plain).foregroundStyle(Theme.secondaryText).iconButtonHelp("Settings…")
        }
        .padding(.top, 2)
    }
}

/// The app icon as a view.
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
