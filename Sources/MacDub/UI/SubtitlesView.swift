import MacDubCore
import SwiftUI

/// Scrolling transcript: every recognized sentence with its translation, plus the live partial.
struct SubtitlesView: View {
    @EnvironmentObject private var state: AppState

    private static let bottomAnchor = "bottom"

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Subtitles").font(.headline)
                Spacer()
                Text("\(state.segments.count)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                Toggle("Auto-scroll", isOn: state.settings.binding(\.autoScrollSubtitles))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                Menu {
                    Button("Subtitles (.srt) — translation") { state.exportTranscript(format: .srt, content: .translated) }
                    Button("Subtitles (.srt) — original") { state.exportTranscript(format: .srt, content: .original) }
                    Button("Subtitles (.srt) — both") { state.exportTranscript(format: .srt, content: .both) }
                    Divider()
                    Button("Markdown (.md) — for AI summaries") { state.exportTranscript(format: .md, content: .both) }
                    Button("Text (.txt) — both") { state.exportTranscript(format: .txt, content: .both) }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .controlSize(.small)
                .disabled(state.segments.isEmpty)
                Button("Clear") { state.clearTranscript() }
                    .controlSize(.small)
                    .disabled(state.segments.isEmpty && state.partialText.isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider().overlay(Color.white.opacity(0.08))

            if isEmpty {
                // The empty state is NOT a row of the transcript, so it does not belong inside
                // the scroll: in there it inherited the stack's leading alignment and sat wherever
                // the top padding left it — pinned near the top of a panel that is mostly empty.
                // As a sibling that fills the panel it centres itself on both axes, which is
                // where the eye looks when there is nothing else to look at.
                ContentUnavailableView {
                    Label(state.phase == .running ? L("Listening…") : L("Nothing yet"),
                          systemImage: state.phase == .running ? "waveform" : "captions.bubble")
                } description: {
                    Text(state.phase == .running
                         ? LF("Play something in %@.", state.selectedTarget?.name ?? L("the captured app"))
                         : L("Press Start dubbing to begin."))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(state.segments) { segment in
                                SegmentRow(segment: segment,
                                           showOriginal: state.settings.showOriginalInSubtitles,
                                           speaking: state.speaking?.segmentID == segment.id ? state.speaking : nil,
                                           highlight: state.settings.highlightSpokenWords)
                                    .id(segment.id)
                            }
                            if !state.partialText.isEmpty {
                                Text(state.partialText)
                                    .italic()
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            // Anchor that always sits below the last row; scrolling to it is reliable
                            // even while rows are still being laid out.
                            Color.clear.frame(height: 1).id(Self.bottomAnchor)
                        }
                        .padding(12)
                    }
                    // Keeps the view pinned to the bottom as rows are added or grow (a row grows when
                    // its translation arrives). This is layout-driven, so it can't race the layout
                    // the way an explicit scrollTo after a state change does.
                    .defaultScrollAnchor(state.settings.autoScrollSubtitles ? .bottom : nil, for: .sizeChanges)
                    .defaultScrollAnchor(.bottom, for: .initialOffset)
                    .onChange(of: state.settings.autoScrollSubtitles) { _, on in
                        if on { scrollToEnd(proxy) }
                    }
                    .onChange(of: state.segments.count) { _, _ in scrollToEnd(proxy) }
                }
            }
        }
        .textSelection(.enabled)
    }

    /// Nothing recognised and nothing being recognised right now.
    private var isEmpty: Bool {
        state.segments.isEmpty && state.partialText.isEmpty
    }

    /// Belt and braces for the moments the size-change anchor doesn't cover (toggling
    /// auto-scroll back on, clearing). No animation: animated scrolls interrupted by the next
    /// partial update never reach the end.
    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        guard state.settings.autoScrollSubtitles else { return }
        DispatchQueue.main.async {
            proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
        }
    }
}

private struct SegmentRow: View {
    let segment: Segment
    let showOriginal: Bool
    let speaking: AppState.SpeakingPosition?
    let highlight: Bool

    private var isSpeaking: Bool { speaking != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if showOriginal {
                Text(segment.original)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let translated = segment.translated {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if highlight, isSpeaking {
                        SpokenText(text: translated, word: speaking?.word,
                                   baseColor: .primary, spokenColor: .accentColor, currentColor: .accentColor,
                                   font: .body.weight(.medium))
                    } else {
                        Text(translated)
                            .font(.body.weight(.medium))
                    }
                    if segment.skipped {
                        Image(systemName: "speaker.slash")
                            .font(.caption).foregroundStyle(.tertiary)
                            .help("Not spoken: the voice was too far behind")
                    }
                    Spacer(minLength: 0)
                    Text(latencyLabel)
                        .font(.caption2).monospacedDigit().foregroundStyle(.quaternary)
                        .help("Seconds after the sentence was recognized: translation returned / voice started")
                }
            } else if segment.failed {
                Label("Translation failed", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            } else {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("translating…").font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSpeaking ? Color.accentColor.opacity(0.10) : Color.clear)
        )
        .overlay(alignment: .leading) {
            if isSpeaking {
                RoundedRectangle(cornerRadius: 2).fill(Color.accentColor).frame(width: 3)
            }
        }
        .animation(.easeOut(duration: 0.15), value: isSpeaking)
    }

    private var latencyLabel: String {
        var parts: [String] = []
        if let t = segment.translationLatency { parts.append(String(format: "tr %.1f", t)) }
        if let s = segment.speechLatency { parts.append(String(format: "spk %.1f", s)) }
        return parts.joined(separator: " · ")
    }
}
