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
    @State private var working = false
    @State private var summary: String?
    @State private var message: String?
    @State private var showSummary = false

    private var provider: SummaryProvider? { providers.first { $0.id == selectedProviderID } }

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
                        Button("Add to Codex") { run { try MCPInstaller.addToCodex(); return L("Added to ~/.codex/config.toml.") } }
                        Menu("Copy…") {
                            Button("Claude Code command") { copy(MCPInstaller.claudeCodeCommand) }
                            Button("JSON (Claude Desktop, Cursor, VS Code…)") { copy(MCPInstaller.jsonSnippet) }
                            Button("TOML (Codex)") { copy(MCPInstaller.codexSnippet) }
                            Button("Server path") { copy(MCPInstaller.serverPath) }
                        }
                        .fixedSize()
                    }
                    .controlSize(.small)
                } else {
                    Text("Run the app from build/MacDub.app (make run) — the MCP helper is bundled by the build script.")
                        .font(.caption).foregroundStyle(.orange)
                }
                HStack {
                    Toggle("Also serve over HTTP on port", isOn: state.settings.binding(\.mcpHTTPEnabled))
                    TextField("", value: state.settings.binding(\.mcpHTTPPort), format: .number)
                        .frame(width: 64)
                        .disabled(state.settings.mcpHTTPEnabled)
                    if let status = state.mcpHTTPStatus {
                        Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .controlSize(.small)
                .help("Streamable HTTP transport at http://127.0.0.1:<port>/mcp (localhost only) for clients that cannot spawn a stdio server, or behind a tunnel for remote assistants.")
                LabeledContent("Keep audio for snippets") {
                    HStack {
                        Slider(value: state.settings.binding(\.audioBufferSeconds), in: 0...120, step: 10)
                        Text(state.settings.audioBufferSeconds == 0 ? L("off") : String(format: "%.0f s", state.settings.audioBufferSeconds))
                            .monospacedDigit().frame(width: 44)
                    }
                }
                .controlSize(.small)
                .help("Seconds of captured audio kept in memory so an assistant can request get_audio_snippet. Never written to disk unless asked.")
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
                    if working { ProgressView().controlSize(.small) } else { Text("Summarize transcript") }
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
            SummarySheet(text: summary ?? "")
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
        working = true
        message = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try SummaryService.summarize(transcript, with: provider, model: model, language: language) }
            DispatchQueue.main.async {
                working = false
                switch result {
                case .success(let text):
                    if provider.isClipboardOnly {
                        message = text
                    } else {
                        summary = text
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

/// Shows a summary with copy / save.
struct SummarySheet: View {
    @Environment(\.dismiss) private var dismiss
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Summary").font(.headline)
            ScrollView {
                Text(text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
