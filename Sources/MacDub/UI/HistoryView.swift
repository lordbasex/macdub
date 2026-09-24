import SwiftUI
import AVFAudio
import UniformTypeIdentifiers
import MacDubCore

/// History section: saved sessions on the left; on the right the recorded audio with its
/// spectrum and transport, and the transcript following the playback karaoke-style.
struct HistorySectionView: View {
    @EnvironmentObject private var state: AppState
    @State private var selectedID: String?
    /// Dubbing sessions or live translation conversations.
    @AppStorage("historyTab") private var tab = HistoryTab.dubbing
    private let palette = Theme.amber

    private var selected: SessionRecord? { state.sessions.first { $0.id == selectedID } }
    private var sessions: [SessionRecord] { state.sessions.filter { $0.isLive == (tab == .live) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 16) {
                HeroTile(symbol: "clock.arrow.circlepath", palette: palette, size: 64)
                    .onReceive(state.$historySelection) { id in if let id { selectedID = id } }
                VStack(alignment: .leading, spacing: 6) {
                    Text("History").font(.system(size: 30, weight: .semibold)).foregroundStyle(.white)
                    Picker("", selection: $tab) {
                        ForEach(HistoryTab.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    .onChange(of: tab) { _, _ in selectedID = nil }
                    Text(tab == .live ? "Every live translation conversation is saved here when it stops."
                                      : "Every dubbing session is saved here when it stops.")
                        .font(.callout).foregroundStyle(Theme.secondaryText)
                }
                Spacer()
                Button { state.refreshSessions() } label: { Image(systemName: "arrow.clockwise") }
                    .iconButtonHelp("Refresh")
                    .buttonStyle(.borderless).foregroundStyle(.white)
                if let record = selected {
                    Menu {
                        if record.audioURL != nil {
                            Button("Audio + subtitles (.m4a + .srt) — translation") { exportAudio(record, .translated) }
                            Button("Audio + subtitles (.m4a + .srt) — original") { exportAudio(record, .original) }
                            Divider()
                        }
                        Button("Subtitles (.srt) — translation") { export(record, .srt, .translated) }
                        Button("Subtitles (.srt) — both") { export(record, .srt, .both) }
                        Button("Markdown (.md) — for AI summaries") { export(record, .md, .both) }
                        Button("Text (.txt) — both") { export(record, .txt, .both) }
                    } label: {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                    .fixedSize()
                    Button(role: .destructive) {
                        state.deleteSession(record)
                        selectedID = nil
                    } label: { Label("Delete", systemImage: "trash") }
                }
            }
            .padding(.horizontal, 32).padding(.top, 40)

            HStack(spacing: 16) {
                GlassCard(padding: 6) {
                    if sessions.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "clock.arrow.circlepath").font(.largeTitle).foregroundStyle(Theme.tertiaryText)
                            Text(tab == .live ? "No conversations yet" : "No sessions yet").foregroundStyle(Theme.secondaryText)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        List(sessions, selection: $selectedID) { record in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    if record.isLive {
                                        Image(systemName: "person.2.wave.2.fill").font(.caption).foregroundStyle(Theme.cyan.accent)
                                    }
                                    Text(record.appName ?? "—").font(.headline).foregroundStyle(.white)
                                    if record.audioURL != nil {
                                        Image(systemName: "waveform").font(.caption).foregroundStyle(palette.top)
                                            .help("Original audio recorded")
                                    }
                                }
                                Text(record.startedAt, format: .dateTime.day().month().year().hour().minute())
                                    .font(.caption).foregroundStyle(Theme.secondaryText)
                                Text(LF(record.isLive ? "%lld sentences · %@ ↔ %@ · %@" : "%lld sentences · %@ → %@ · %@",
                                        record.sentenceCount, record.sourceLocale, record.targetLanguage, durationText(record.duration)))
                                    .font(.caption2).foregroundStyle(Theme.tertiaryText)
                            }
                            .padding(.vertical, 4)
                            .tag(record.id)
                        }
                        .scrollContentBackground(.hidden)
                        .listStyle(.plain)
                    }
                }
                .frame(width: 300)

                GlassCard(padding: 0) {
                    if let record = selected {
                        SessionDetailView(record: record)
                            .id(record.id) // a new player per session
                    } else {
                        Text("Select a session").foregroundStyle(Theme.secondaryText)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            .padding(.horizontal, 32).padding(.bottom, 28)
        }
        .onAppear { state.refreshSessions() }
    }

    /// Who spoke, at the start of each exported line of a conversation.
    static var sideLabels: [String: String] { ["me": L("You"), "them": L("Them")] }

    private func durationText(_ t: TimeInterval) -> String {
        let m = Int(t) / 60, s = Int(t) % 60
        return m > 0 ? "\(m) min \(s) s" : "\(s) s"
    }

    private func savePanel(name: String, type: UTType?) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        if let type { panel.allowedContentTypes = [type] }
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        NSApp.activate(ignoringOtherApps: true)
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func export(_ record: SessionRecord, _ format: TranscriptExporter.Format, _ content: TranscriptExporter.Content) {
        guard let url = savePanel(name: "\(record.exportBaseName(kind: "transcript")).\(format.fileExtension)", type: nil) else { return }
        do {
            try record.render(format, content: content, sideLabels: Self.sideLabels).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            state.present(message: LF("Could not save the file: %@", error.localizedDescription), suggestion: nil)
        }
    }

    /// Writes `<base>.m4a` and `<base>.srt` side by side: same name, so VLC & co. load the
    /// subtitles automatically when the audio is opened.
    private func exportAudio(_ record: SessionRecord, _ content: TranscriptExporter.Content) {
        guard let audio = record.audioURL else { return }
        guard let chosen = savePanel(name: "\(record.exportBaseName()).\(MacDubPaths.audioExtension)", type: .mpeg4Audio) else { return }
        let base = chosen.deletingPathExtension()
        let audioDest = base.appendingPathExtension(MacDubPaths.audioExtension)
        let srtDest = base.appendingPathExtension("srt")
        do {
            if FileManager.default.fileExists(atPath: audioDest.path) { try FileManager.default.removeItem(at: audioDest) }
            try FileManager.default.copyItem(at: audio, to: audioDest)
            try record.render(.srt, content: content, sideLabels: Self.sideLabels).write(to: srtDest, atomically: true, encoding: .utf8)
            NSWorkspace.shared.activateFileViewerSelecting([audioDest, srtDest])
        } catch {
            state.present(message: LF("Could not save the file: %@", error.localizedDescription), suggestion: nil)
        }
    }
}

/// History's two tabs.
enum HistoryTab: String, CaseIterable, Identifiable {
    case dubbing, live
    var id: String { rawValue }
    var title: LocalizedStringKey { self == .live ? "Live translation" : "Dubbing" }
    var symbol: String { self == .live ? "person.2.wave.2.fill" : "waveform.and.mic" }
}

/// What History plays: the recorded audio, the translated voice over it, or the voice alone.
enum HistoryAudioMode: String, CaseIterable, Identifiable {
    case original, documentary, voice
    var id: String { rawValue }
    var title: LocalizedStringKey {
        switch self {
        case .original: return "Original audio only"
        case .documentary: return "Documentary: original low + translated voice"
        case .voice: return "Translated voice only"
        }
    }
    var symbol: String {
        switch self {
        case .original: return "waveform"
        case .documentary: return "waveform.badge.mic"
        case .voice: return "person.wave.2"
        }
    }
    var speaks: Bool { self != .original }
}

/// Which text the transcript shows while playing.
enum HistorySubtitleMode: String, CaseIterable, Identifiable {
    case original, translation, both
    var id: String { rawValue }
    var title: LocalizedStringKey {
        switch self {
        case .original: return "Original text"
        case .translation: return "Translation"
        case .both: return "Both"
        }
    }
    var showsOriginal: Bool { self != .translation }
    var showsTranslation: Bool { self != .original }
}

/// Player (when the session has audio) on top of the transcript, which follows the playback.
private struct SessionDetailView: View {
    let record: SessionRecord
    @EnvironmentObject private var state: AppState
    @StateObject private var player = SessionPlayer()
    @State private var loadError: String?
    private let cues: [TranscriptExporter.Cue]
    private let script: [SessionPlayer.Line]

    init(record: SessionRecord) {
        self.record = record
        cues = TranscriptExporter.cues(for: record.segments.map(\.segment), sessionStart: record.startedAt)
        script = zip(record.segments, cues).map { SessionPlayer.Line(cue: $1, translated: $0.translated) }
    }

    private var audioMode: HistoryAudioMode { HistoryAudioMode(rawValue: state.settings.historyAudioMode) ?? .original }
    private var subtitleMode: HistorySubtitleMode { HistorySubtitleMode(rawValue: state.settings.historySubtitleMode) ?? .both }

    /// Index of the cue on screen at `t`: the active one, or the last one already passed
    /// (so the transcript keeps its place between sentences).
    private var currentIndex: Int? {
        let t = player.currentTime
        if let active = cues.firstIndex(where: { $0.contains(t) }) { return active }
        return cues.lastIndex(where: { $0.end <= t })
    }

    var body: some View {
        VStack(spacing: 0) {
            if record.audioURL != nil {
                PlayerBar(player: player, meter: player.meter, audioMode: audioMode)
                    .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)
                Divider().overlay(Color.white.opacity(0.08))
            } else {
                Label("No audio was recorded for this session.", systemImage: "waveform.slash")
                    .font(.caption).foregroundStyle(Theme.tertiaryText)
                    .padding(.horizontal, 16).padding(.top, 12)
            }
            if let loadError {
                Text(loadError).font(.caption).foregroundStyle(.orange).padding(.horizontal, 16)
            }
            transcript
        }
        .onAppear {
            guard let url = record.audioURL else { return }
            applyVoiceSettings()
            applyModes()
            do { try player.load(url, script: script) } catch { loadError = LF("Could not open the audio: %@", error.localizedDescription) }
        }
        .onDisappear { player.stop() }
        .onChange(of: state.settings.historyAudioMode) { _, _ in applyModes() }
        .onChange(of: state.settings.historyOriginalVolume) { _, _ in applyModes() }
        .onChange(of: state.settings.voiceIdentifier) { _, _ in applyVoiceSettings() }
    }

    private func applyModes() {
        switch audioMode {
        case .original: player.originalVolume = 1
        case .documentary: player.originalVolume = Float(state.settings.historyOriginalVolume)
        case .voice: player.originalVolume = 0
        }
        player.speakTranslation = audioMode.speaks
    }

    /// Same voice/rate/catch-up as the live dub, for the language this session was translated to.
    private func applyVoiceSettings() {
        let settings = state.settings
        let voice = player.voice
        let chosen = settings.voiceIdentifier.isEmpty ? nil : AVSpeechSynthesisVoice(identifier: settings.voiceIdentifier)
        let target = record.targetLanguage.lowercased()
        let matches = chosen.map { $0.language.lowercased().hasPrefix(String(target.prefix(2))) } ?? false
        voice.voiceIdentifier = matches ? chosen?.identifier : nil
        voice.language = VoiceSynthesisManager.voices(forLanguageCode: String(target.prefix(2))).first?.language ?? record.targetLanguage
        voice.rate = Float(settings.speechRate)
        voice.volume = Float(settings.volume)
        voice.maxBacklog = settings.maxBacklog
        voice.catchUpBoost = Float(settings.catchUpBoost)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(record.segments.enumerated()), id: \.offset) { index, seg in
                        let cue = cues[index]
                        let isCurrent = currentIndex == index
                        let isActive = isCurrent && cue.contains(player.currentTime)
                        let progress = cue.progress(at: player.currentTime)
                        Group {
                            if record.isLive {
                                ConversationBubble(segment: seg, offset: cue.start, isCurrent: isCurrent, subtitles: subtitleMode)
                            } else {
                                HistoryRow(segment: seg, offset: cue.start, isCurrent: isCurrent, subtitles: subtitleMode,
                                           originalWord: isActive ? Karaoke.wordRange(in: seg.original, progress: progress) : nil,
                                           translatedWord: translatedWord(index: index, segment: seg, isActive: isActive, progress: progress))
                            }
                        }
                        .id(index)
                        .onTapGesture { if record.audioURL != nil { player.seek(to: cue.start) } }
                    }
                }
                .padding(16)
            }
            .textSelection(.enabled)
            .onChange(of: currentIndex) { _, index in
                guard player.isPlaying, let index else { return }
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(index, anchor: .center) }
            }
        }
    }

    /// Karaoke on the translation: the word the voice is saying when the voice plays, else the
    /// cue's progress spread over the translated words.
    private func translatedWord(index: Int, segment: LiveState.SegmentDTO, isActive: Bool, progress: Double) -> NSRange? {
        guard let translated = segment.translated else { return nil }
        if audioMode.speaks {
            guard let spoken = player.spokenWord, spoken.index == index else { return nil }
            return spoken.range
        }
        return isActive ? Karaoke.wordRange(in: translated, progress: progress) : nil
    }
}

/// A line of a live translation conversation: yours on the right in cyan, theirs on the left,
/// like a chat, with how long each step took.
private struct ConversationBubble: View {
    let segment: LiveState.SegmentDTO
    let offset: TimeInterval
    let isCurrent: Bool
    let subtitles: HistorySubtitleMode

    private var mine: Bool { segment.side == "me" }

    var body: some View {
        HStack {
            if mine { Spacer(minLength: 60) }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(mine ? "You" : "Them").font(.caption.weight(.semibold))
                        .foregroundStyle(mine ? Theme.cyan.accent : Theme.secondaryText)
                    if let author = segment.author { Text(author).font(.caption).foregroundStyle(Theme.secondaryText) }
                    if segment.via == "chat" { Image(systemName: "bubble.left.fill").font(.caption2).foregroundStyle(Theme.cyan.accent) }
                    if segment.via == "typed" { Image(systemName: "keyboard").font(.caption2).foregroundStyle(Theme.cyan.accent) }
                    Text(TranscriptExporter.clock(offset)).font(.caption2).monospacedDigit()
                        .foregroundStyle(isCurrent ? Color.yellow : Theme.tertiaryText)
                }
                if subtitles.showsOriginal {
                    Text(segment.original).font(subtitles == .original ? .body.weight(.medium) : .callout)
                        .foregroundStyle(subtitles == .original ? .white : Theme.secondaryText)
                }
                if subtitles.showsTranslation, let t = segment.translated {
                    Text(t).font(.body.weight(.medium)).foregroundStyle(isCurrent ? Color.yellow.opacity(0.95) : .white)
                }
                if let timings { Text(timings).font(.caption2).monospacedDigit().foregroundStyle(Theme.tertiaryText) }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background((mine ? Theme.cyan.accent.opacity(0.18) : Color.white.opacity(0.08)),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(isCurrent ? Color.yellow.opacity(0.6) : .clear))
            if !mine { Spacer(minLength: 60) }
        }
        .contentShape(Rectangle())
    }

    private var timings: String? {
        let spoken = segment.spokenAt
        let parts = [
            segment.speechEndedAt.map { LF("Transcription %.1f s", segment.recognizedAt.timeIntervalSince($0)) },
            spoken.map { LF("Audio %.1f s", $0.timeIntervalSince(segment.recognizedAt)) },
            spoken.map { LF("Total %.1f s", $0.timeIntervalSince(segment.speechEndedAt ?? segment.recognizedAt)) },
        ].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: "  ·  ")
    }
}

private struct HistoryRow: View {
    let segment: LiveState.SegmentDTO
    let offset: TimeInterval
    let isCurrent: Bool
    let subtitles: HistorySubtitleMode
    /// Word of the original being said right now (karaoke), nil when this sentence is not playing.
    let originalWord: NSRange?
    /// Word of the translation being said right now.
    let translatedWord: NSRange?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(TranscriptExporter.clock(offset))
                    .font(.caption2).monospacedDigit().foregroundStyle(isCurrent ? Color.yellow : Theme.tertiaryText)
                if subtitles.showsOriginal {
                    if originalWord != nil {
                        SpokenText(text: segment.original, word: originalWord,
                                   baseColor: Theme.secondaryText, spokenColor: .white, currentColor: .yellow, font: originalFont)
                    } else {
                        Text(segment.original).font(originalFont).foregroundStyle(isCurrent ? .white : Theme.secondaryText)
                    }
                } else if let t = segment.translated {
                    translation(t)
                }
            }
            if subtitles == .both, let t = segment.translated {
                translation(t)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(isCurrent ? Color.white.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
    }

    /// The original is the main line when it is alone, secondary when the translation is under it.
    private var originalFont: Font { subtitles == .original ? .body.weight(.medium) : .callout }

    @ViewBuilder
    private func translation(_ text: String) -> some View {
        if translatedWord != nil {
            SpokenText(text: text, word: translatedWord,
                       baseColor: .white, spokenColor: Color.yellow.opacity(0.9), currentColor: .yellow, font: .body.weight(.medium))
        } else {
            Text(text).font(.body.weight(.medium)).foregroundStyle(isCurrent ? Color.yellow.opacity(0.9) : .white)
        }
    }
}

/// Spectrum + play/pause + scrubber + the playback-mode menu.
private struct PlayerBar: View {
    @ObservedObject var player: SessionPlayer
    @ObservedObject var meter: SpectrumMeter
    let audioMode: HistoryAudioMode
    @EnvironmentObject private var state: AppState
    @State private var scrubbing = false
    @State private var scrubValue: Double = 0

    var body: some View {
        VStack(spacing: 10) {
            ZStack(alignment: .topTrailing) {
                SpectrumView(bands: meter.bands, palette: Theme.amber)
                    .frame(height: 56)
                    .opacity(audioMode == .voice ? 0.35 : 1)
                modeMenu
            }
            HStack(spacing: 12) {
                Button { player.toggle() } label: {
                    Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 30)).foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.space, modifiers: [])
                .help("Play / pause (space)")
                Text(TranscriptExporter.clock(scrubbing ? scrubValue : player.currentTime))
                    .font(.caption).monospacedDigit().foregroundStyle(Theme.secondaryText)
                Slider(value: Binding(get: { scrubbing ? scrubValue : player.currentTime },
                                      set: { scrubValue = $0 }),
                       in: 0...max(player.duration, 0.01)) { editing in
                    scrubbing = editing
                    if !editing { player.seek(to: scrubValue) }
                }
                .tint(Theme.amber.top)
                Text(TranscriptExporter.clock(player.duration))
                    .font(.caption).monospacedDigit().foregroundStyle(Theme.tertiaryText)
            }
            if audioMode == .documentary {
                HStack(spacing: 8) {
                    Image(systemName: "speaker.wave.1").font(.caption).foregroundStyle(Theme.tertiaryText)
                    Text("Original under the voice").font(.caption).foregroundStyle(Theme.secondaryText)
                    Slider(value: state.settings.binding(\.historyOriginalVolume), in: 0...1)
                        .tint(Theme.amber.top).frame(maxWidth: 220)
                    Text("\(Int(state.settings.historyOriginalVolume * 100)) %")
                        .font(.caption).monospacedDigit().foregroundStyle(Theme.secondaryText).frame(width: 40, alignment: .trailing)
                    Spacer()
                }
            }
        }
    }

    /// Audio × subtitles, remembered in Settings.
    private var modeMenu: some View {
        Menu {
            Picker("Audio", selection: state.settings.binding(\.historyAudioMode)) {
                ForEach(HistoryAudioMode.allCases) { mode in Label(mode.title, systemImage: mode.symbol).tag(mode.rawValue) }
            }
            .pickerStyle(.inline)
            Picker("Subtitles", selection: state.settings.binding(\.historySubtitleMode)) {
                ForEach(HistorySubtitleMode.allCases) { mode in Text(mode.title).tag(mode.rawValue) }
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: audioMode.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Color.white.opacity(0.12), in: Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Playback: what you hear and which text you read")
    }
}

/// Bars of the spectrum, drawn in one Canvas pass (cheap at 30 Hz).
private struct SpectrumView: View {
    let bands: [Float]
    let palette: Theme.Palette

    var body: some View {
        Canvas { context, size in
            let count = max(1, bands.count)
            let gap: CGFloat = 3
            let width = (size.width - gap * CGFloat(count - 1)) / CGFloat(count)
            for (i, value) in bands.enumerated() {
                let h = max(2, CGFloat(value) * size.height)
                let rect = CGRect(x: CGFloat(i) * (width + gap), y: size.height - h, width: width, height: h)
                let shape = Path(roundedRect: rect, cornerRadius: width / 2)
                context.fill(shape, with: .linearGradient(
                    Gradient(colors: [palette.top, Color.yellow]),
                    startPoint: CGPoint(x: 0, y: size.height), endPoint: CGPoint(x: 0, y: 0)))
            }
        }
        .accessibilityHidden(true)
    }
}
