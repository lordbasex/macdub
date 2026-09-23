import Foundation
import AppKit
import MacDubCore

// MARK: - Shell helpers

enum Shell {
    /// Runs a command through the user's login shell so PATH additions (Homebrew, npm, ~/.local)
    /// are visible — a GUI app inherits almost no PATH.
    @discardableResult
    static func run(_ command: String, stdin: String? = nil, timeout: TimeInterval = 240) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = out
        var inputPipe: Pipe?
        if stdin != nil {
            inputPipe = Pipe()
            process.standardInput = inputPipe
        }
        try process.run()
        if let stdin, let inputPipe {
            inputPipe.fileHandleForWriting.write(stdin.data(using: .utf8) ?? Data())
            try? inputPipe.fileHandleForWriting.close()
        }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        if process.isRunning { process.terminate() }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, stripTerminalEscapes(String(data: data, encoding: .utf8) ?? ""))
    }

    /// CLIs print OSC title sequences (`ESC ] 0 ; claude BEL`) and colour codes even when piped.
    static func stripTerminalEscapes(_ s: String) -> String {
        var text = s
        for pattern in ["\u{1B}\\][^\u{07}\u{1B}]*(\u{07}|\u{1B}\\\\)", "\u{1B}\\[[0-9;?]*[A-Za-z]"] {
            text = text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        return text
    }

    /// Absolute path of a CLI tool, or nil.
    static func which(_ tool: String) -> String? {
        guard let result = try? run("command -v \(tool)", timeout: 10), result.status == 0 else { return nil }
        let path = result.output.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").last.map(String.init) ?? ""
        return path.hasPrefix("/") ? path : nil
    }

    static func appExists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: "/Applications/\(name).app")
            || FileManager.default.fileExists(atPath: NSHomeDirectory() + "/Applications/\(name).app")
    }
}

// MARK: - MCP registration

/// Registers the bundled `macdub-mcp` server with the MCP clients found on this Mac.
///
/// Clients are pointed at a small launcher in Application Support rather than at the bundle,
/// so the registration survives moving MacDub.app (the app records its location on every
/// launch and the launcher follows it).
enum MCPInstaller {
    /// The helper inside the running bundle.
    static var serverURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/macdub-mcp")
    }

    static var isBundled: Bool { FileManager.default.isExecutableFile(atPath: serverURL.path) }

    static let appPathFile = LiveStateStore.directory.appendingPathComponent("app-path")
    static let launcherURL = LiveStateStore.directory.appendingPathComponent("bin/macdub-mcp")

    /// What gets registered with clients: the launcher when it could be written, else the bundle path.
    static var serverPath: String {
        FileManager.default.isExecutableFile(atPath: launcherURL.path) ? launcherURL.path : serverURL.path
    }

    private static let launcherScript = """
    #!/bin/sh
    # MacDub MCP launcher — written by MacDub on launch. Finds the app wherever it lives now,
    # so MCP clients registered against this path keep working after the app is moved.
    DIR="$HOME/Library/Application Support/MacDub"
    APP="$(cat "$DIR/app-path" 2>/dev/null)"
    [ -x "$APP/Contents/Helpers/macdub-mcp" ] || APP="/Applications/MacDub.app"
    [ -x "$APP/Contents/Helpers/macdub-mcp" ] || APP="$HOME/Applications/MacDub.app"
    [ -x "$APP/Contents/Helpers/macdub-mcp" ] || APP="$(mdfind "kMDItemCFBundleIdentifier == 'com.lordbasex.MacDub'" 2>/dev/null | head -1)"
    if [ ! -x "$APP/Contents/Helpers/macdub-mcp" ]; then
      echo "macdub-mcp launcher: MacDub.app not found — open MacDub once so it records its location" >&2
      exit 1
    fi
    exec "$APP/Contents/Helpers/macdub-mcp" "$@"

    """

    /// Called on every launch: records where the app is and (re)writes the launcher.
    static func recordAppLocation() {
        guard isBundled else { return } // `swift run` builds have no helper; leave any launcher alone
        do {
            try FileManager.default.createDirectory(at: launcherURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Bundle.main.bundleURL.path.write(to: appPathFile, atomically: true, encoding: .utf8)
            if (try? String(contentsOf: launcherURL, encoding: .utf8)) != launcherScript {
                try launcherScript.write(to: launcherURL, atomically: true, encoding: .utf8)
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcherURL.path)
        } catch {
            Log.app.error("MCP launcher: \(error.localizedDescription, privacy: .public)")
        }
    }

    static var claudeCodeCommand: String { "claude mcp add --scope user macdub \"\(serverPath)\"" }

    static var jsonSnippet: String {
        """
        {
          "mcpServers": {
            "macdub": { "command": "\(serverPath)" }
          }
        }
        """
    }

    static var codexSnippet: String {
        """
        [mcp_servers.macdub]
        command = "\(serverPath)"
        """
    }

    static let claudeDesktopConfig = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
    static let codexConfig = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/config.toml")

    static var hasClaudeDesktop: Bool { Shell.appExists("Claude") || FileManager.default.fileExists(atPath: claudeDesktopConfig.deletingLastPathComponent().path) }
    static var hasCodex: Bool { FileManager.default.fileExists(atPath: codexConfig.deletingLastPathComponent().path) }

    /// `claude mcp add …` through the CLI. Returns the CLI output.
    static func addToClaudeCode() throws -> String {
        let r = try Shell.run(claudeCodeCommand, timeout: 60)
        guard r.status == 0 else { throw IntegrationError.failed(r.output) }
        return r.output
    }

    /// Merges `mcpServers.macdub` into Claude Desktop's config file (created if missing).
    static func addToClaudeDesktop() throws {
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: claudeDesktopConfig),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = existing
        }
        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        servers["macdub"] = ["command": serverPath]
        root["mcpServers"] = servers
        try FileManager.default.createDirectory(at: claudeDesktopConfig.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: claudeDesktopConfig, options: .atomic)
    }

    /// Appends the `[mcp_servers.macdub]` table to Codex's config.toml unless already present.
    static func addToCodex() throws {
        var text = (try? String(contentsOf: codexConfig, encoding: .utf8)) ?? ""
        if text.contains("[mcp_servers.macdub]") {
            // Replace the command line of the existing table.
            let lines = text.components(separatedBy: "\n")
            var out: [String] = []
            var inTable = false
            for line in lines {
                if line.trimmingCharacters(in: .whitespaces) == "[mcp_servers.macdub]" { inTable = true; out.append(line); continue }
                if inTable, line.hasPrefix("[") { inTable = false }
                if inTable, line.trimmingCharacters(in: .whitespaces).hasPrefix("command") {
                    out.append("command = \"\(serverPath)\""); continue
                }
                out.append(line)
            }
            text = out.joined(separator: "\n")
        } else {
            if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
            text += "\n" + codexSnippet + "\n"
        }
        try FileManager.default.createDirectory(at: codexConfig.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: codexConfig, atomically: true, encoding: .utf8)
    }
}

enum IntegrationError: LocalizedError {
    case failed(String)
    case notAvailable
    var errorDescription: String? {
        switch self {
        case .failed(let output): return output.trimmingCharacters(in: .whitespacesAndNewlines)
        case .notAvailable: return L("That assistant is not installed.")
        }
    }
}

// MARK: - Summaries with local assistants

/// An assistant found on this Mac that can summarise the transcript.
struct SummaryProvider: Identifiable, Hashable {
    enum Kind: String { case appleIntelligence, claudeCode, codex, ollama, lmStudio, claudeDesktop, chatGPT }

    let kind: Kind
    let title: String
    /// Absolute path of the CLI (Claude Code / Codex); several copies may be installed.
    var command: String?
    /// Local model servers expose several models.
    var models: [String] = []

    var id: String { kind.rawValue }
    var needsModel: Bool { kind == .ollama || kind == .lmStudio }
    /// Providers without an API: we put the prompt on the clipboard and open the app.
    var isClipboardOnly: Bool { kind == .claudeDesktop || kind == .chatGPT }
}

enum SummaryService {
    /// Detects assistants. Slow-ish (spawns a login shell, probes two local ports); call off the main thread.
    static func detectProviders() -> [SummaryProvider] {
        var found: [SummaryProvider] = []
        if LocalLLM.appleAvailable {
            found.append(SummaryProvider(kind: .appleIntelligence, title: "Apple Intelligence (on-device)"))
        }
        if let claude = newestCLI("claude", extra: ["~/.claude/local/claude", "~/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]) {
            found.append(SummaryProvider(kind: .claudeCode, title: "Claude Code (CLI \(claude.version))", command: claude.path))
        }
        if let codex = newestCLI("codex", extra: ["/opt/homebrew/bin/codex", "/usr/local/bin/codex", "~/.local/bin/codex"]) {
            found.append(SummaryProvider(kind: .codex, title: "Codex (CLI \(codex.version))", command: codex.path))
        }
        let ollama = LocalLLM.ollamaModels()
        if !ollama.isEmpty { found.append(SummaryProvider(kind: .ollama, title: "Ollama", models: ollama)) }
        let lm = LocalLLM.lmStudioModels()
        if !lm.isEmpty { found.append(SummaryProvider(kind: .lmStudio, title: "LM Studio", models: lm)) }
        if Shell.appExists("Claude") { found.append(SummaryProvider(kind: .claudeDesktop, title: "Claude Desktop (paste)")) }
        if Shell.appExists("ChatGPT") { found.append(SummaryProvider(kind: .chatGPT, title: "ChatGPT (paste)")) }
        return found
    }

    /// Several copies of a CLI can coexist (npm global, Homebrew, the self-updating one in
    /// ~/.claude/local). An outdated `claude` only knows retired model names and fails with 404,
    /// so pick the highest `--version` among the candidates.
    static func newestCLI(_ tool: String, extra: [String]) -> (path: String, version: String)? {
        var candidates = extra.map { NSString(string: $0).expandingTildeInPath }
        if let onPath = Shell.which(tool) { candidates.insert(onPath, at: 0) }
        var best: (path: String, version: [Int], display: String)?
        for path in Set(candidates) where FileManager.default.isExecutableFile(atPath: path) {
            guard let r = try? Shell.run("\"\(path)\" --version", timeout: 15), r.status == 0 else { continue }
            let display = r.output.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n").first ?? ""
            let numbers = display.split(whereSeparator: { !$0.isNumber && $0 != "." })
                .first { $0.contains(".") }.map { $0.split(separator: ".").compactMap { Int($0) } } ?? []
            if let current = best {
                if current.version.lexicographicallyPrecedes(numbers) { best = (path, numbers, display) }
            } else {
                best = (path, numbers, display)
            }
        }
        guard let best else { return nil }
        let short = best.version.map(String.init).joined(separator: ".")
        return (best.path, short.isEmpty ? best.display : short)
    }

    static func prompt(language: String) -> String {
        LocalLLM.summaryInstructions(language: language)
    }

    /// A summary and what it cost. `inputTokens`/`outputTokens` are nil for clipboard-only providers.
    struct SummaryResult {
        var text: String
        var inputTokens: Int?
        var outputTokens: Int?
        var tokensEstimated = false
        var costUSD: Double?

        init(text: String, inputTokens: Int? = nil, outputTokens: Int? = nil, tokensEstimated: Bool = false, costUSD: Double? = nil) {
            self.text = text
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
            self.tokensEstimated = tokensEstimated
            self.costUSD = costUSD
        }

        init(_ chat: LocalLLM.ChatResult) {
            self.init(text: chat.text, inputTokens: chat.inputTokens, outputTokens: chat.outputTokens, tokensEstimated: chat.tokensEstimated)
        }
    }

    /// Runs the summary. Blocking; call off the main thread.
    static func summarize(_ transcript: String, with provider: SummaryProvider, model: String?, language: String) throws -> SummaryResult {
        let instructions = prompt(language: language)
        switch provider.kind {
        case .appleIntelligence:
            return SummaryResult(try LocalLLM.chatWithUsage(provider: .apple, model: nil, system: instructions, user: transcript))
        case .claudeCode:
            let cli = provider.command.map { "\"\($0)\"" } ?? "claude"
            let r = try Shell.run("\(cli) -p \(shellQuote(instructions)) --output-format json", stdin: transcript)
            guard r.status == 0 else { throw IntegrationError.failed(r.output) }
            return try parsed(AssistantOutput.claudeCode(r.output), input: instructions + transcript) ?? estimated(r.output, input: instructions + transcript)
        case .codex:
            let cli = provider.command.map { "\"\($0)\"" } ?? "codex"
            let full = instructions + "\n\n---\n\n" + transcript
            let r = try Shell.run("\(cli) exec --json --skip-git-repo-check -", stdin: full)
            // Older Codex CLIs without --json events: keep the plain output and estimate.
            if let result = try parsed(AssistantOutput.codexExec(r.output), input: full) { return result }
            guard r.status == 0 else { throw IntegrationError.failed(r.output) }
            return estimated(r.output, input: full)
        case .ollama:
            return SummaryResult(try LocalLLM.chatWithUsage(provider: .ollama, model: model, system: instructions, user: transcript))
        case .lmStudio:
            return SummaryResult(try LocalLLM.chatWithUsage(provider: .lmstudio, model: model, system: instructions, user: transcript))
        case .claudeDesktop, .chatGPT:
            let text = instructions + "\n\n---\n\n" + transcript
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            let app = provider.kind == .claudeDesktop ? "Claude" : "ChatGPT"
            NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/\(app).app"))
            return SummaryResult(text: L("The prompt and transcript were copied to the clipboard — paste them (⌘V) into the assistant that just opened."))
        }
    }

    private static func estimated(_ output: String, input: String) -> SummaryResult {
        SummaryResult(LocalLLM.ChatResult(text: output).estimatingMissing(input: input))
    }

    /// A parsed CLI reply as a summary; a reply flagged as an error becomes the thrown error.
    private static func parsed(_ p: AssistantOutput.Parsed?, input: String) throws -> SummaryResult? {
        guard let p else { return nil }
        if p.isError { throw IntegrationError.failed(p.text) }
        if p.inputTokens == nil || p.outputTokens == nil {
            return estimated(p.text, input: input)
        }
        return SummaryResult(text: p.text, inputTokens: p.inputTokens, outputTokens: p.outputTokens, costUSD: p.costUSD)
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
