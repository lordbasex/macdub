import SwiftUI
import MacDubCore

/// Saved sessions: list on the left, transcript on the right, export/delete.
struct HistoryView: View {
    static let windowID = "history"

    @EnvironmentObject private var state: AppState
    @State private var selectedID: String?

    private var selected: SessionRecord? { state.sessions.first { $0.id == selectedID } }

    var body: some View {
        NavigationSplitView {
            List(state.sessions, selection: $selectedID) { record in
                VStack(alignment: .leading, spacing: 2) {
                    Text(record.appName ?? "—").font(.headline)
                    Text(record.startedAt, format: .dateTime.day().month().year().hour().minute())
                        .font(.caption).foregroundStyle(.secondary)
                    Text(LF("%lld sentences · %@ → %@ · %@", record.sentenceCount, record.sourceLocale,
                            record.targetLanguage, durationText(record.duration)))
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                .tag(record.id)
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
            .overlay {
                if state.sessions.isEmpty {
                    ContentUnavailableView("No sessions yet", systemImage: "clock.arrow.circlepath",
                                           description: Text("Each dubbing session is saved here when it stops."))
                }
            }
        } detail: {
            if let record = selected {
                SessionDetailView(record: record)
            } else {
                Text("Select a session").foregroundStyle(.secondary)
            }
        }
        .navigationTitle(Text("History"))
        .toolbar {
            ToolbarItemGroup {
                Button { state.refreshSessions() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                if let record = selected {
                    Menu {
                        Button("Subtitles (.srt) — translation") { export(record, .srt, .translated) }
                        Button("Subtitles (.srt) — both") { export(record, .srt, .both) }
                        Button("Markdown (.md) — for AI summaries") { export(record, .md, .both) }
                        Button("Text (.txt) — both") { export(record, .txt, .both) }
                    } label: {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                    Button(role: .destructive) {
                        state.deleteSession(record)
                        selectedID = nil
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
        .frame(minWidth: 760, minHeight: 460)
        .onAppear { state.refreshSessions() }
    }

    private func durationText(_ t: TimeInterval) -> String {
        let m = Int(t) / 60, s = Int(t) % 60
        return m > 0 ? "\(m) min \(s) s" : "\(s) s"
    }

    private func export(_ record: SessionRecord, _ format: TranscriptExporter.Format, _ content: TranscriptExporter.Content) {
        let panel = NSSavePanel()
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH.mm"
        panel.nameFieldStringValue = "MacDub \(df.string(from: record.startedAt)).\(format.fileExtension)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? record.render(format, content: content).write(to: url, atomically: true, encoding: .utf8)
    }
}

private struct SessionDetailView: View {
    let record: SessionRecord

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(record.segments.enumerated()), id: \.offset) { _, seg in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(TranscriptExporter.clock(seg.recognizedAt.timeIntervalSince(record.startedAt)))
                                .font(.caption2).monospacedDigit().foregroundStyle(.tertiary)
                            Text(seg.original).font(.callout).foregroundStyle(.secondary)
                        }
                        if let t = seg.translated {
                            Text(t).font(.body.weight(.medium))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(14)
        }
        .textSelection(.enabled)
    }
}
