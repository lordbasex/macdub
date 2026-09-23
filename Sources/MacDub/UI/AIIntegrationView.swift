import SwiftUI
import MacDubCore

/// Settings section: register the MCP server with local assistants, and summarise the
/// transcript with whatever assistant is installed on this Mac.
struct AIIntegrationSection: View {
    @EnvironmentObject private var state: AppState
    @State private var providers: [SummaryProvider] = []
    @State private var selectedProviderID = ""
    @State private var selectedModel = ""
    @State private var detecting = false
    /// When the running summary started; nil while idle. Drives the live seconds counter.
    @State private var startedAt: Date?
    @State private var summary: String?
    @State private var stats: SummaryStats?
    @State private var message: String?
    @State private var showSummary = false

    private var provider: SummaryProvider? { providers.first { $0.id == selectedProviderID } }
    private var working: Bool { startedAt != nil }

    var body: some View {
        Section("AI assistants & MCP") {
            // MCP
            VStack(alignment: .leading, spacing: 6) {
                Text("MCP server: lets Claude Code, Claude Desktop, Codex or any MCP client read the live transcript and control dubbing. Registrations point at a launcher that follows the app if you move it.")
                    .font(.caption).foregroundStyle(.secondary)
                if MCPInstaller.isBundled {
                    HStack {
                        Button("Add to Claude Code") { run { try MCPInstaller.addToClaudeCode() } }
                        Button("Add to Claude Desktop") { run { try MCPInstaller.addToClaudeDesktop(); return L("Added. Restart Claude Desktop.") } }
                    }
                    HStack {
                        Button("Add to Codex") { run { try MCPInstaller.addToCodex(); return L("Added to ~/.codex/config.toml.") } }
                        Menu("Copy…") {
                            Button("Claude Code command") { copy(MCPInstaller.claudeCodeCommand) }
                            Button("JSON (Claude Desktop, Cursor, VS Code…)") { copy(MCPInstaller.jsonSnippet) }
                            Button("TOML (Codex)") { copy(MCPInstaller.codexSnippet) }
                            Button("Server path") { copy(MCPInstaller.serverPath) }
                        }
                        .fixedSize()
                    }
                } else {
                    Text("Run the app from build/MacDub.app (make run) — the MCP helper is bundled by the build script.")
                        .font(.caption).foregroundStyle(.orange)
                }
            }

            // Summaries
            HStack {
                Picker("Summarize with", selection: $selectedProviderID) {
                    if providers.isEmpty {
                        Text(detecting ? L("Detecting…") : L("No assistant found")).tag("")
                    }
                    ForEach(providers) { p in Text(p.title).tag(p.id) }
                }
                Button {
                    detect()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Detect installed assistants again (Claude Code, Codex, Ollama, LM Studio, Claude Desktop, ChatGPT)")
            }
            if let provider, provider.needsModel {
                Picker("Model", selection: $selectedModel) {
                    ForEach(provider.models, id: \.self) { Text($0).tag($0) }
                }
            }
            HStack {
                Button {
                    summarize()
                } label: {
                    if let startedAt {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            TimelineView(.periodic(from: startedAt, by: 0.1)) { context in
                                Text(LF("Summarizing… %@", SummaryStats.seconds(context.date.timeIntervalSince(startedAt))))
                                    .monospacedDigit()
                            }
                        }
                    } else {
                        Text("Summarize transcript")
                    }
                }
                .disabled(provider == nil || working || state.segments.isEmpty)
                if summary != nil {
                    Button("Show last summary") { showSummary = true }
                }
                if let message {
                    Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
        .onAppear { if providers.isEmpty { detect() } }
        .onChange(of: selectedProviderID) { _, _ in selectedModel = provider?.models.first ?? "" }
        .sheet(isPresented: $showSummary) {
            SummarySheet(text: summary ?? "", stats: stats)
        }
    }

    private func detect() {
        detecting = true
        DispatchQueue.global(qos: .userInitiated).async {
            let found = SummaryService.detectProviders()
            DispatchQueue.main.async {
                providers = found
                detecting = false
                if !found.contains(where: { $0.id == selectedProviderID }) { selectedProviderID = found.first?.id ?? "" }
                selectedModel = provider?.models.first ?? ""
            }
        }
    }

    private func summarize() {
        guard let provider else { return }
        let transcript = state.transcriptMarkdown()
        let language = state.settings.targetLanguageID
        let model = selectedModel.isEmpty ? nil : selectedModel
        let start = Date()
        startedAt = start
        message = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try SummaryService.summarize(transcript, with: provider, model: model, language: language) }
            let elapsed = Date().timeIntervalSince(start)
            DispatchQueue.main.async {
                startedAt = nil
                switch result {
                case .success(let r):
                    if provider.isClipboardOnly {
                        message = r.text
                    } else {
                        let title = provider.needsModel && model != nil ? "\(provider.title) · \(model!)" : provider.title
                        let s = SummaryStats(provider: title, seconds: elapsed, result: r)
                        summary = r.text
                        stats = s
                        message = s.line
                        showSummary = true
                    }
                case .failure(let error):
                    message = error.localizedDescription
                }
            }
        }
    }

    private func run(_ action: @escaping () throws -> String) {
        message = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try action() }
            DispatchQueue.main.async {
                switch result {
                case .success(let out): message = out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? L("Done.") : out
                case .failure(let error): message = error.localizedDescription
                }
            }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        message = L("Copied.")
    }
}

/// How long a summary took and how many tokens it used.
struct SummaryStats {
    let provider: String
    let seconds: TimeInterval
    let inputTokens: Int?
    let outputTokens: Int?
    let estimated: Bool
    let costUSD: Double?

    init(provider: String, seconds: TimeInterval, result: SummaryService.SummaryResult) {
        self.provider = provider
        self.seconds = seconds
        inputTokens = result.inputTokens
        outputTokens = result.outputTokens
        estimated = result.tokensEstimated
        costUSD = result.costUSD
    }

    /// "12.3 s", with the locale's decimal separator.
    static func seconds(_ value: TimeInterval) -> String {
        value.formatted(.number.precision(.fractionLength(1))) + " s"
    }

    var tokens: String? {
        guard let inputTokens, let outputTokens else { return nil }
        let text = LF("%@ tokens (%@ in · %@ out)",
                      (inputTokens + outputTokens).formatted(), inputTokens.formatted(), outputTokens.formatted())
        return estimated ? "≈ " + text : text
    }

    /// One line: time · tokens · cost.
    var line: String {
        var parts = [LF("Took %@", Self.seconds(seconds))]
        if let tokens { parts.append(tokens) }
        if let costUSD { parts.append(String(format: "US$ %.4f", costUSD)) }
        return parts.joined(separator: " · ")
    }
}

/// Shows a summary with copy / save.
struct SummarySheet: View {
    @Environment(\.dismiss) private var dismiss
    let text: String
    var stats: SummaryStats?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Summary").font(.headline)
            ScrollView {
                Text(text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let stats {
                VStack(alignment: .leading, spacing: 2) {
                    Label(stats.provider, systemImage: "sparkles")
                    Label(LF("Took %@", SummaryStats.seconds(stats.seconds)), systemImage: "timer")
                    if let tokens = stats.tokens {
                        Label(tokens, systemImage: "number")
                    }
                    if let cost = stats.costUSD {
                        Label(String(format: "US$ %.4f", cost), systemImage: "dollarsign.circle")
                    }
                    if stats.estimated {
                        Text("≈ estimated: this assistant does not report tokens (about 4 characters per token).")
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
                Divider()
            }
            HStack {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                Button("Save…") { save() }
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(16)
        .frame(width: 560, height: 480)
    }

    private func save() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "MacDub summary.md"
        if panel.runModal() == .OK, let url = panel.url {
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
