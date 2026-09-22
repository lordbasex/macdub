// macdub-mcp — Model Context Protocol server (stdio transport) for MacDub.
//
// Lets Claude Code, Claude Desktop, Codex, ChatGPT and any MCP-capable IDE read the live
// transcript, browse saved sessions and control dubbing. It does not touch audio itself: it
// reads the snapshot MacDub keeps in ~/Library/Application Support/MacDub/live.json (and the
// session files next to it) and sends commands to the running app through
// DistributedNotificationCenter.
//
// Register with Claude Code:   claude mcp add macdub /Applications/MacDub.app/Contents/Helpers/macdub-mcp
// Protocol: JSON-RPC 2.0, one message per line on stdin/stdout (MCP 2025-06-18).
// Capabilities: tools, resources (live transcript/status), prompts (summaries, action items).
import Foundation
import MacDubCore

let serverName = "macdub"
let serverVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
let protocolVersion = "2025-06-18"
let iso = ISO8601DateFormatter()

// MARK: - Helpers

enum ToolError: Error, LocalizedError {
    case appNotRunning
    case invalidArgument(String)
    case notFound(String)

    var errorDescription: String? {
        switch self {
        case .appNotRunning: return "MacDub is not running (or has never written its live state). Launch MacDub first."
        case .invalidArgument(let m): return m
        case .notFound(let m): return m
        }
    }
}

func liveState() throws -> LiveState {
    let state = try LiveStateStore.read()
    guard LiveStateStore.isAppAlive(state) else { throw ToolError.appNotRunning }
    return state
}

func jsonString(_ object: Any) -> String {
    let data = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    return String(data: data, encoding: .utf8) ?? "{}"
}

func content(_ name: String?) -> TranscriptExporter.Content {
    switch name { case "original": return .original; case "translated": return .translated; default: return .both }
}

func statusObject(_ s: LiveState) -> [String: Any] {
    [
        "phase": s.phase,
        "voice": s.voiceIdentifier as Any,
        "speakTranslation": s.speakTranslation,
        "originalVolume": s.originalVolume,
        "duckOnlyWhileSpeaking": s.duckOnlyWhileSpeaking,
        "availableSourceLocales": s.availableSourceLocales,
        "availableTargetLanguages": s.availableTargetLanguages,
        "availableVoices": s.availableVoices.map { ["identifier": $0.identifier, "name": $0.name, "language": $0.language, "quality": $0.quality] },
        "target": s.target.map { ["name": $0.name, "bundleIdentifier": $0.bundleIdentifier] } as Any,
        "sourceLocale": s.sourceLocale,
        "targetLanguage": s.targetLanguage,
        "sessionStart": iso.string(from: s.sessionStart),
        "sentences": s.segments.count,
        "partial": s.partial,
        "captureEngine": s.captureEngine as Any,
        "recognitionEngine": s.recognitionEngine as Any,
        "silentForSeconds": s.silentFor as Any,
        "latency": ["translationSeconds": s.translationLatency, "speechSeconds": s.speechLatency],
        "updatedAt": iso.string(from: s.updatedAt),
        "availableTargets": s.availableTargets.map { ["name": $0.name, "bundleIdentifier": $0.bundleIdentifier] },
    ]
}

/// A slice of a transcript: `all` is the full session, `selected` the sentences after filtering,
/// `firstIndex` the index (0-based, in `all`) of the first selected sentence.
struct Slice {
    let all: [Segment]
    let selected: [Segment]
    let firstIndex: Int
    var nextIndex: Int { firstIndex + selected.count }
}

/// Applies `last`, `sinceIndex`, `fromSeconds` / `toSeconds` to a session's sentences.
func slice(_ all: [Segment], args: [String: Any], sessionStart: Date) throws -> Slice {
    var indexed = Array(all.enumerated())
    if let since = args["sinceIndex"] as? Int {
        guard since >= 0 else { throw ToolError.invalidArgument("sinceIndex must be ≥ 0") }
        indexed = indexed.filter { $0.offset >= since }
    }
    if let from = args["fromSeconds"] as? Double {
        indexed = indexed.filter { $0.element.recognizedAt.timeIntervalSince(sessionStart) >= from }
    }
    if let to = args["toSeconds"] as? Double {
        indexed = indexed.filter { $0.element.recognizedAt.timeIntervalSince(sessionStart) <= to }
    }
    if let last = args["last"] as? Int, last > 0 {
        indexed = Array(indexed.suffix(last))
    }
    return Slice(all: all, selected: indexed.map(\.element), firstIndex: indexed.first?.offset ?? all.count)
}

func renderTranscript(_ s: Slice, format: String, content: TranscriptExporter.Content,
                      sessionStart: Date, metadata: TranscriptExporter.Metadata, rangeFooter: Bool = false) throws -> String {
    let segments = s.selected
    if format == "json" {
        let items = segments.enumerated().map { i, seg -> [String: Any] in
            var d: [String: Any] = [
                "index": s.firstIndex + i,
                "offsetSeconds": (seg.recognizedAt.timeIntervalSince(sessionStart) * 10).rounded() / 10,
                "recognizedAt": iso.string(from: seg.recognizedAt),
                "original": seg.original,
            ]
            if let t = seg.translated { d["translated"] = t }
            return d
        }
        return jsonString(["total": s.all.count, "count": segments.count, "firstIndex": s.firstIndex,
                           "nextIndex": s.nextIndex, "sentences": items])
    }
    guard let fmt = TranscriptExporter.Format(rawValue: format) else {
        throw ToolError.invalidArgument("Unknown format '\(format)' (md, txt, srt, json)")
    }
    var text = TranscriptExporter.render(segments, format: fmt, content: content, sessionStart: sessionStart, metadata: metadata)
    if text.isEmpty { text = "(no sentences in this range)" }
    // Incremental readers need to know where to continue; keep it out of .srt to stay parseable.
    if fmt != .srt, rangeFooter {
        text += "\n\n<!-- sentences \(s.firstIndex)–\(max(s.firstIndex, s.nextIndex - 1)) of \(s.all.count); nextIndex=\(s.nextIndex) -->"
    }
    return text
}

func hasRangeArgs(_ args: [String: Any]) -> Bool {
    args["sinceIndex"] != nil || args["fromSeconds"] != nil || args["toSeconds"] != nil || args["last"] != nil
}

let rangeProperties: [String: Any] = [
    "last": ["type": "integer", "minimum": 1, "description": "Only the last N sentences"],
    "sinceIndex": ["type": "integer", "minimum": 0, "description": "Only sentences with index ≥ this (incremental reads: pass the nextIndex you got last time)"],
    "fromSeconds": ["type": "number", "minimum": 0, "description": "Only sentences recognized at or after this offset from session start"],
    "toSeconds": ["type": "number", "minimum": 0, "description": "Only sentences recognized at or before this offset"],
]

// MARK: - Tools

struct Tool {
    let name: String
    let description: String
    let schema: [String: Any]
    let run: ([String: Any]) throws -> String
}

let formatProperty: [String: Any] = ["type": "string", "enum": ["md", "txt", "srt", "json"], "description": "Output format (default md)"]
let contentProperty: [String: Any] = ["type": "string", "enum": ["both", "original", "translated"], "description": "Which text to include (default both)"]

let tools: [Tool] = [
    Tool(
        name: "get_status",
        description: "Current MacDub state: phase (idle/running), captured app, languages, engines in use, latency, silence, sentence count, and the apps that can be captured.",
        schema: ["type": "object", "properties": [:]],
        run: { _ in jsonString(statusObject(try liveState())) }
    ),
    Tool(
        name: "get_transcript",
        description: "Transcript of the current/last dubbing session. `format`: md (default, best for summarising), txt, srt or json (json carries indices, offsets and nextIndex). `content`: both (default), original or translated. Ranges: `last` N sentences, `sinceIndex` for incremental reads, `fromSeconds`/`toSeconds` for a time window.",
        schema: ["type": "object", "properties": ["format": formatProperty, "content": contentProperty].merging(rangeProperties) { a, _ in a }],
        run: { args in
            let s = try liveState()
            let sl = try slice(s.segments.map(\.segment), args: args, sessionStart: s.sessionStart)
            let meta = TranscriptExporter.Metadata(appName: s.target?.name, sourceLanguage: s.sourceLocale, targetLanguage: s.targetLanguage)
            return try renderTranscript(sl, format: (args["format"] as? String) ?? "md",
                                        content: content(args["content"] as? String), sessionStart: s.sessionStart,
                                        metadata: meta, rangeFooter: hasRangeArgs(args))
        }
    ),
    Tool(
        name: "summarize_transcript",
        description: "Summarise the current session (or a saved one with `sessionId`) using a LOCAL model on this Mac — Apple Intelligence (macOS 26), Ollama or LM Studio — so the transcript never has to enter your context. `provider`: auto (default, on-device first), apple, ollama, lmstudio. `model` for Ollama/LM Studio (default: first available). `language`: summary language (default: dubbing target). Accepts the same range arguments as get_transcript. Returns the summary text, or an error listing what is available.",
        schema: ["type": "object", "properties": [
            "provider": ["type": "string", "enum": ["auto", "apple", "ollama", "lmstudio"]],
            "model": ["type": "string"],
            "language": ["type": "string", "description": "e.g. es, en, pt-BR"],
            "sessionId": ["type": "string", "description": "A saved session instead of the live one"],
            "instructions": ["type": "string", "description": "Override the default summary instructions"],
        ].merging(rangeProperties) { a, _ in a }],
        run: { args in
            let segments: [Segment]
            let sessionStart: Date
            let meta: TranscriptExporter.Metadata
            let targetLanguage: String
            if let id = args["sessionId"] as? String {
                guard let record = try? SessionStore.load(id: id) else { throw ToolError.notFound("No session with id \(id)") }
                segments = record.segments.map(\.segment); sessionStart = record.startedAt; meta = record.metadata; targetLanguage = record.targetLanguage
            } else {
                let s = try liveState()
                segments = s.segments.map(\.segment); sessionStart = s.sessionStart; targetLanguage = s.targetLanguage
                meta = TranscriptExporter.Metadata(appName: s.target?.name, sourceLanguage: s.sourceLocale, targetLanguage: s.targetLanguage)
            }
            let sl = try slice(segments, args: args, sessionStart: sessionStart)
            guard !sl.selected.isEmpty else { throw ToolError.invalidArgument("Nothing to summarise (empty transcript or range).") }
            let transcript = TranscriptExporter.render(sl.selected, format: .md, content: .both, sessionStart: sessionStart, metadata: meta)

            let available = LocalLLM.availableProviders()
            guard !available.isEmpty else {
                throw ToolError.notFound("No local model available. Install Ollama (ollama.com) or LM Studio, or use Apple Intelligence on macOS 26 — or read get_transcript and summarise it yourself.")
            }
            let wanted = (args["provider"] as? String) ?? "auto"
            let choice: (LocalLLM.Provider, [String])
            if wanted == "auto" {
                choice = available[0]
            } else {
                guard let p = LocalLLM.Provider(rawValue: wanted), let found = available.first(where: { $0.0 == p }) else {
                    throw ToolError.notFound("Provider '\(wanted)' is not available. Available: \(available.map { $0.0.rawValue })")
                }
                choice = found
            }
            var model = args["model"] as? String ?? choice.1.first
            if let m = model, !choice.1.isEmpty, !choice.1.contains(m) {
                throw ToolError.notFound("Model '\(m)' not found for \(choice.0.rawValue). Available: \(choice.1)")
            }
            if choice.0 == .apple { model = nil }
            let instructions = (args["instructions"] as? String) ?? LocalLLM.summaryInstructions(language: (args["language"] as? String) ?? targetLanguage)
            let summary = try LocalLLM.chat(provider: choice.0, model: model, system: instructions, user: transcript)
            return summary.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n<!-- summarised by \(choice.0.rawValue)\(model.map { " / \($0)" } ?? "") over \(sl.selected.count) sentences -->"
        }
    ),
    Tool(
        name: "export_session",
        description: "Write the current session (or a saved one with `sessionId`) to a file on disk as srt, md or txt, so the assistant can keep working with the file (e.g. hand a subtitle track to a video). `path` defaults to ~/Downloads/MacDub <date>.<ext>. Returns the absolute path.",
        schema: ["type": "object", "properties": [
            "sessionId": ["type": "string"],
            "format": ["type": "string", "enum": ["srt", "md", "txt"], "description": "Default srt"],
            "content": contentProperty,
            "path": ["type": "string", "description": "Destination file (~ allowed). Parent folders are created."],
            "overwrite": ["type": "boolean", "description": "Replace an existing file (default false)"],
        ].merging(rangeProperties) { a, _ in a }],
        run: { args in
            let segments: [Segment]
            let sessionStart: Date
            let meta: TranscriptExporter.Metadata
            if let id = args["sessionId"] as? String {
                guard let record = try? SessionStore.load(id: id) else { throw ToolError.notFound("No session with id \(id)") }
                segments = record.segments.map(\.segment); sessionStart = record.startedAt; meta = record.metadata
            } else {
                let s = try liveState()
                segments = s.segments.map(\.segment); sessionStart = s.sessionStart
                meta = TranscriptExporter.Metadata(appName: s.target?.name, sourceLanguage: s.sourceLocale, targetLanguage: s.targetLanguage)
            }
            let sl = try slice(segments, args: args, sessionStart: sessionStart)
            guard !sl.selected.isEmpty else { throw ToolError.invalidArgument("Nothing to export (empty transcript or range).") }
            let formatName = (args["format"] as? String) ?? "srt"
            guard let format = TranscriptExporter.Format(rawValue: formatName) else { throw ToolError.invalidArgument("format must be srt, md or txt") }
            let text = TranscriptExporter.render(sl.selected, format: format, content: content(args["content"] as? String),
                                                 sessionStart: sessionStart, metadata: meta)

            let url: URL
            if let given = args["path"] as? String, !given.isEmpty {
                url = URL(fileURLWithPath: NSString(string: given).expandingTildeInPath)
            } else {
                let df = DateFormatter()
                df.dateFormat = "yyyy-MM-dd HH.mm"
                let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                    ?? URL(fileURLWithPath: NSHomeDirectory())
                url = downloads.appendingPathComponent("MacDub \(df.string(from: sessionStart)).\(format.fileExtension)")
            }
            if FileManager.default.fileExists(atPath: url.path), (args["overwrite"] as? Bool) != true {
                throw ToolError.invalidArgument("\(url.path) already exists; pass overwrite: true to replace it.")
            }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
            return "Wrote \(sl.selected.count) sentences (\(format.rawValue)) to \(url.path)"
        }
    ),
    Tool(
        name: "get_audio_snippet",
        description: "The last N seconds of the captured audio as a 16 kHz mono WAV (default 15 s, max what MacDub keeps — 60 s by default, see Settings › Keep audio for snippets). Use it to double-check a dubious sentence with an audio-capable model. Returns the file path; `inline: true` (≤ 30 s) also embeds the audio in the response.",
        schema: ["type": "object", "properties": [
            "seconds": ["type": "number", "minimum": 1, "maximum": 120, "description": "Length of the snippet (default 15)"],
            "path": ["type": "string", "description": "Destination .wav (default: a temp file under MacDub's Application Support folder)"],
            "inline": ["type": "boolean", "description": "Embed the WAV as audio content (only for snippets ≤ 30 s)"],
        ]],
        run: { args in
            let s = try liveState()
            guard s.phase == "running" || !s.segments.isEmpty else { throw ToolError.invalidArgument("Nothing captured yet — start dubbing first.") }
            let seconds = min(120, max(1, (args["seconds"] as? Double) ?? 15))
            let url: URL
            if let given = args["path"] as? String, !given.isEmpty {
                url = URL(fileURLWithPath: NSString(string: given).expandingTildeInPath)
            } else {
                let dir = LiveStateStore.directory.appendingPathComponent("snippets", isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                url = dir.appendingPathComponent("snippet-\(Int(Date().timeIntervalSince1970)).wav")
            }
            let errorURL = url.appendingPathExtension("error")
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: errorURL)
            MacDubCommand.post(.exportAudio, values: ["seconds": String(seconds), "path": url.path])

            // The app writes the file asynchronously; wait for it (or for an error marker).
            let deadline = Date().addingTimeInterval(8)
            while Date() < deadline {
                if FileManager.default.fileExists(atPath: url.path) { break }
                if let message = try? String(contentsOf: errorURL, encoding: .utf8) {
                    try? FileManager.default.removeItem(at: errorURL)
                    throw ToolError.invalidArgument(message)
                }
                Thread.sleep(forTimeInterval: 0.15)
            }
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw ToolError.invalidArgument("MacDub did not produce the snippet (is audio buffering enabled in Settings › AI assistants & MCP?).")
            }
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            var text = "Wrote \(Int(seconds)) s of audio (\(size / 1024) KB, 16 kHz mono WAV) to \(url.path)"
            if (args["inline"] as? Bool) == true {
                guard seconds <= 30 else { throw ToolError.invalidArgument("inline is limited to 30 s; the file was still written to \(url.path)") }
                let data = try Data(contentsOf: url)
                text += "\n<<audio:" + data.base64EncodedString() + ">>"
            }
            return text
        }
    ),
    Tool(
        name: "list_local_models",
        description: "Which local summarisation providers/models are available on this Mac (Apple Intelligence, Ollama, LM Studio).",
        schema: ["type": "object", "properties": [:]],
        run: { _ in
            let available = LocalLLM.availableProviders()
            if available.isEmpty { return "None. Install Ollama (ollama.com) or LM Studio, or use Apple Intelligence on macOS 26." }
            return jsonString(available.map { ["provider": $0.0.rawValue, "models": $0.1] })
        }
    ),
    Tool(
        name: "search_transcript",
        description: "Find sentences in the current session containing a word or phrase (case-insensitive, original and translation). Returns matches with timestamps.",
        schema: ["type": "object", "required": ["query"],
                 "properties": ["query": ["type": "string"], "limit": ["type": "integer", "minimum": 1, "description": "Max matches (default 20)"]]],
        run: { args in
            guard let query = (args["query"] as? String)?.trimmingCharacters(in: .whitespaces), !query.isEmpty else {
                throw ToolError.invalidArgument("query is required")
            }
            let s = try liveState()
            let limit = (args["limit"] as? Int) ?? 20
            let hits = s.segments.filter {
                $0.original.localizedCaseInsensitiveContains(query) || ($0.translated?.localizedCaseInsensitiveContains(query) ?? false)
            }.prefix(limit)
            if hits.isEmpty { return "No matches for “\(query)”." }
            return hits.map { seg in
                "[\(TranscriptExporter.clock(seg.recognizedAt.timeIntervalSince(s.sessionStart)))] \(seg.original)" + (seg.translated.map { "\n    \($0)" } ?? "")
            }.joined(separator: "\n")
        }
    ),
    Tool(
        name: "list_sessions",
        description: "Saved dubbing sessions (newest first): id, app, start time, duration, languages, sentence count. Use get_session to read one.",
        schema: ["type": "object", "properties": ["limit": ["type": "integer", "minimum": 1, "description": "Max sessions (default 20)"]]],
        run: { args in
            let limit = (args["limit"] as? Int) ?? 20
            let list = SessionStore.list().prefix(limit).map { r -> [String: Any] in
                ["id": r.id, "app": r.appName as Any, "startedAt": iso.string(from: r.startedAt), "durationSeconds": Int(r.duration),
                 "sourceLocale": r.sourceLocale, "targetLanguage": r.targetLanguage, "sentences": r.sentenceCount]
            }
            return list.isEmpty ? "No saved sessions." : jsonString(list)
        }
    ),
    Tool(
        name: "get_session",
        description: "Transcript of a saved session by id (see list_sessions). Same format/content/range options as get_transcript.",
        schema: ["type": "object", "required": ["id"], "properties": ["id": ["type": "string"], "format": formatProperty, "content": contentProperty].merging(rangeProperties) { a, _ in a }],
        run: { args in
            guard let id = args["id"] as? String else { throw ToolError.invalidArgument("id is required") }
            guard let record = try? SessionStore.load(id: id) else { throw ToolError.notFound("No session with id \(id)") }
            let sl = try slice(record.segments.map(\.segment), args: args, sessionStart: record.startedAt)
            return try renderTranscript(sl, format: (args["format"] as? String) ?? "md",
                                        content: content(args["content"] as? String), sessionStart: record.startedAt,
                                        metadata: record.metadata, rangeFooter: hasRangeArgs(args))
        }
    ),
    Tool(
        name: "start_dubbing",
        description: "Start dubbing the selected application, or pick one first by bundle identifier (see get_status.availableTargets; use \"system\" for all system audio).",
        schema: ["type": "object", "properties": ["bundleIdentifier": ["type": "string", "description": "App to capture, e.g. com.google.Chrome, or system"]]],
        run: { args in
            let before = try liveState()
            let bundle = args["bundleIdentifier"] as? String
            MacDubCommand.post(.start, bundleIdentifier: bundle)
            // Confirm within a few seconds so the caller gets a real answer, not a promise.
            let deadline = Date().addingTimeInterval(6)
            while Date() < deadline {
                Thread.sleep(forTimeInterval: 0.3)
                if let now = try? LiveStateStore.read(), now.updatedAt > before.updatedAt {
                    if now.phase == "running" {
                        return "Dubbing \(now.target?.name ?? "") (\(now.captureEngine ?? "-") / \(now.recognitionEngine ?? "-"))."
                    }
                    if let bundle, now.target?.bundleIdentifier != bundle, now.phase == "idle" {
                        return "Could not select \(bundle) — is it running? Available: \(now.availableTargets.map(\.bundleIdentifier))"
                    }
                }
            }
            return "Start requested; MacDub has not confirmed yet — call get_status (a permission or model error may be showing in the app)."
        }
    ),
    Tool(
        name: "stop_dubbing",
        description: "Stop dubbing. The session is archived (see list_sessions).",
        schema: ["type": "object", "properties": [:]],
        run: { _ in _ = try liveState(); MacDubCommand.post(.stop); return "Stop requested." }
    ),
    Tool(
        name: "set_languages",
        description: "Change the spoken (source) locale and/or the translation target. Only applied while idle — stop first. Valid values: get_status.availableSourceLocales / availableTargetLanguages.",
        schema: ["type": "object", "properties": [
            "sourceLocale": ["type": "string", "description": "e.g. en-US"],
            "targetLanguage": ["type": "string", "description": "e.g. es, pt-BR, fr"],
        ]],
        run: { args in
            let s = try liveState()
            guard s.phase == "idle" else { throw ToolError.invalidArgument("MacDub is \(s.phase); call stop_dubbing first.") }
            var values: [String: String] = [:]
            if let v = args["sourceLocale"] as? String {
                guard s.availableSourceLocales.contains(v) else { throw ToolError.invalidArgument("sourceLocale must be one of \(s.availableSourceLocales)") }
                values["sourceLocale"] = v
            }
            if let v = args["targetLanguage"] as? String {
                guard s.availableTargetLanguages.contains(v) else { throw ToolError.invalidArgument("targetLanguage must be one of \(s.availableTargetLanguages)") }
                values["targetLanguage"] = v
            }
            guard !values.isEmpty else { throw ToolError.invalidArgument("Give sourceLocale and/or targetLanguage") }
            MacDubCommand.post(.setLanguages, values: values)
            return "Languages updated: \(values)."
        }
    ),
    Tool(
        name: "set_voice",
        description: "Choose the system voice by identifier or by name (see get_status.availableVoices). Applies to the next sentence, also while dubbing.",
        schema: ["type": "object", "properties": [
            "voice": ["type": "string", "description": "Voice identifier (com.apple.voice…) or name (e.g. Paulina)"],
        ], "required": ["voice"]],
        run: { args in
            let s = try liveState()
            guard let wanted = args["voice"] as? String else { throw ToolError.invalidArgument("voice is required") }
            let match = s.availableVoices.first { $0.identifier == wanted }
                ?? s.availableVoices.first { $0.name.localizedCaseInsensitiveCompare(wanted) == .orderedSame }
                ?? s.availableVoices.first { $0.name.localizedCaseInsensitiveContains(wanted) }
            guard let match else { throw ToolError.notFound("No voice matching '\(wanted)'. Available: \(s.availableVoices.map(\.name))") }
            MacDubCommand.post(.setVoice, values: ["voiceIdentifier": match.identifier])
            return "Voice set to \(match.name) (\(match.language), \(match.quality))."
        }
    ),
    Tool(
        name: "set_speak",
        description: "Turn the translated voice on or off (subtitles keep flowing either way).",
        schema: ["type": "object", "properties": ["enabled": ["type": "boolean"]], "required": ["enabled"]],
        run: { args in
            _ = try liveState()
            guard let enabled = args["enabled"] as? Bool else { throw ToolError.invalidArgument("enabled (boolean) is required") }
            MacDubCommand.post(.setSpeak, values: ["enabled": enabled ? "true" : "false"])
            return enabled ? "Voice enabled." : "Voice muted (subtitles only)."
        }
    ),
    Tool(
        name: "set_original_volume",
        description: "Level of the original audio under the dub, 0–1 (tap engine only), and whether to lower it only while the voice speaks. Applies immediately.",
        schema: ["type": "object", "properties": [
            "level": ["type": "number", "minimum": 0, "maximum": 1],
            "duckOnlyWhileSpeaking": ["type": "boolean"],
        ]],
        run: { args in
            _ = try liveState()
            var values: [String: String] = [:]
            if let level = args["level"] as? Double { values["level"] = String(min(1, max(0, level))) }
            if let duck = args["duckOnlyWhileSpeaking"] as? Bool { values["duckOnlyWhileSpeaking"] = duck ? "true" : "false" }
            guard !values.isEmpty else { throw ToolError.invalidArgument("Give level and/or duckOnlyWhileSpeaking") }
            MacDubCommand.post(.setOriginalVolume, values: values)
            return "Original audio updated: \(values)."
        }
    ),
    Tool(
        name: "clear_transcript",
        description: "Clear the current transcript in MacDub (the next dubbing starts a fresh session).",
        schema: ["type": "object", "properties": [:]],
        run: { _ in _ = try liveState(); MacDubCommand.post(.clearTranscript); return "Transcript cleared." }
    ),
]

// MARK: - Resources (read-only views a client can attach as context)

struct Resource {
    let uri: String
    let name: String
    let description: String
    let mimeType: String
    let read: () throws -> String
}

/// `macdub://sessions/<id>` (Markdown) or `macdub://sessions/<id>/<md|txt|srt|json>`.
let sessionTemplate = "macdub://sessions/{id}"
let sessionFormatTemplate = "macdub://sessions/{id}/{format}"

func mime(for format: String) -> String {
    switch format {
    case "srt": return "application/x-subrip"
    case "json": return "application/json"
    case "txt": return "text/plain"
    default: return "text/markdown"
    }
}

/// Resolves a session URI to (mimeType, text). nil when the URI is not a session URI.
func readSessionResource(_ uri: String) throws -> (String, String)? {
    guard uri.hasPrefix("macdub://sessions/") else { return nil }
    let parts = uri.dropFirst("macdub://sessions/".count).split(separator: "/").map(String.init)
    guard let id = parts.first, !id.isEmpty else { return nil }
    let format = parts.count > 1 ? parts[1] : "md"
    guard let record = try? SessionStore.load(id: id) else { throw ToolError.notFound("No session with id \(id)") }
    let all = record.segments.map(\.segment)
    let text = try renderTranscript(Slice(all: all, selected: all, firstIndex: 0), format: format, content: .both,
                                    sessionStart: record.startedAt, metadata: record.metadata)
    return (mime(for: format), text)
}

/// One resource entry per saved session so clients can attach past sessions directly.
func sessionResources(limit: Int = 50) -> [[String: Any]] {
    SessionStore.list().prefix(limit).map { r in
        ["uri": "macdub://sessions/\(r.id)", "name": r.title,
         "description": "Saved session: \(r.appName ?? "—"), \(r.sourceLocale) → \(r.targetLanguage), \(r.sentenceCount) sentences, \(Int(r.duration)) s",
         "mimeType": "text/markdown"]
    }
}

let resources: [Resource] = [
    Resource(uri: "macdub://transcript", name: "Live transcript (Markdown)",
             description: "The current dubbing session as Markdown, refreshed as MacDub runs.", mimeType: "text/markdown",
             read: {
                 let s = try liveState()
                 let meta = TranscriptExporter.Metadata(appName: s.target?.name, sourceLanguage: s.sourceLocale, targetLanguage: s.targetLanguage)
                 let all = s.segments.map(\.segment)
                 return try renderTranscript(Slice(all: all, selected: all, firstIndex: 0), format: "md", content: .both, sessionStart: s.sessionStart, metadata: meta)
             }),
    Resource(uri: "macdub://status", name: "MacDub status", description: "Phase, app, languages, engines and latency as JSON.",
             mimeType: "application/json", read: { jsonString(statusObject(try liveState())) }),
]

// MARK: - Prompts (reusable instructions a client can offer as slash commands)

struct Prompt {
    let name: String
    let description: String
    let arguments: [[String: Any]]
    let build: ([String: String]) throws -> String
}

func transcriptForPrompt() throws -> String {
    let s = try liveState()
    let meta = TranscriptExporter.Metadata(appName: s.target?.name, sourceLanguage: s.sourceLocale, targetLanguage: s.targetLanguage)
    let all = s.segments.map(\.segment)
    return try renderTranscript(Slice(all: all, selected: all, firstIndex: 0), format: "md", content: .both, sessionStart: s.sessionStart, metadata: meta)
}

let prompts: [Prompt] = [
    Prompt(name: "summarize", description: "Summarise what was said in the current MacDub session.",
           arguments: [["name": "language", "description": "Language for the summary (default: the dubbing target language)", "required": false]],
           build: { args in
               let s = try liveState()
               let lang = args["language"] ?? s.targetLanguage
               return "Summarise the following transcript in \(lang): a short overview, the key points as bullets, and any names, numbers, decisions or action items worth remembering.\n\n" + (try transcriptForPrompt())
           }),
    Prompt(name: "action_items", description: "Extract decisions and action items (who / what / when) from the current session — meetings.",
           arguments: [],
           build: { _ in "From this meeting transcript, list decisions and action items as a table (owner, task, deadline if mentioned), then open questions.\n\n" + (try transcriptForPrompt()) }),
    Prompt(name: "check_translation", description: "Review the machine translation for mistakes and propose corrections.",
           arguments: [],
           build: { _ in "Compare each original sentence with its translation below. List the sentences whose translation is wrong or misleading, with a corrected version. Ignore minor style differences.\n\n" + (try transcriptForPrompt()) }),
]

// MARK: - Transports

let outputQueue = DispatchQueue(label: "macdub-mcp.output")

func writeStdout(_ object: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: object),
          var line = String(data: data, encoding: .utf8) else { return }
    line += "\n"
    outputQueue.sync { FileHandle.standardOutput.write(line.data(using: .utf8)!) }
}

/// Where server-initiated notifications go: stdout in stdio mode, SSE streams in HTTP mode.
nonisolated(unsafe) var notificationSink: ([String: Any]) -> Void = writeStdout

func send(_ object: [String: Any]) { notificationSink(object) }

// MARK: - Resource subscriptions (live updates without polling)

/// Watches the MacDub data directory; when `live.json` is replaced and the subscribed view
/// actually changed, emits `notifications/resources/updated`. Throttled to ~2 per second.
final class LiveWatcher {
    private let queue = DispatchQueue(label: "macdub-mcp.watch")
    private var source: DispatchSourceFileSystemObject?
    private var fd: Int32 = -1
    private var pending = false
    private(set) var subscriptions = Set<String>()
    private var lastTranscriptKey = ""
    private var lastStatusKey = ""

    func subscribe(_ uri: String) {
        queue.sync {
            subscriptions.insert(uri)
            if source == nil { start() }
            if let s = try? LiveStateStore.read() { remember(s) } // baseline, no spurious first event
        }
    }

    func unsubscribe(_ uri: String) {
        queue.sync {
            subscriptions.remove(uri)
            if subscriptions.isEmpty { stop() }
        }
    }

    private func start() {
        let dir = LiveStateStore.directory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .extend], queue: queue)
        src.setEventHandler { [weak self] in self?.scheduleCheck() }
        src.setCancelHandler { [fd] in close(fd) }
        src.resume()
        source = src
    }

    private func stop() {
        source?.cancel()
        source = nil
        fd = -1
    }

    private func scheduleCheck() {
        guard !pending else { return }
        pending = true
        queue.asyncAfter(deadline: .now() + .milliseconds(400)) { [weak self] in
            guard let self else { return }
            self.pending = false
            self.check()
        }
    }

    private func check() {
        guard let s = try? LiveStateStore.read() else { return }
        // The transcript resource has no partial text, so only sentences/translations count.
        let transcriptKey = "\(s.segments.count)|\(s.segments.last?.translated ?? "")"
        let statusKey = "\(s.phase)|\(s.target?.bundleIdentifier ?? "")|\(s.recognitionEngine ?? "")|\(s.captureEngine ?? "")|\(s.voiceIdentifier ?? "")|\(s.originalVolume)|\(s.speakTranslation)"
        if subscriptions.contains("macdub://transcript"), transcriptKey != lastTranscriptKey {
            send(["jsonrpc": "2.0", "method": "notifications/resources/updated", "params": ["uri": "macdub://transcript"]])
        }
        if subscriptions.contains("macdub://status"), statusKey != lastStatusKey {
            send(["jsonrpc": "2.0", "method": "notifications/resources/updated", "params": ["uri": "macdub://status"]])
        }
        lastTranscriptKey = transcriptKey
        lastStatusKey = statusKey
    }

    private func remember(_ s: LiveState) {
        lastTranscriptKey = "\(s.segments.count)|\(s.segments.last?.translated ?? "")"
        lastStatusKey = "\(s.phase)|\(s.target?.bundleIdentifier ?? "")|\(s.recognitionEngine ?? "")|\(s.captureEngine ?? "")|\(s.voiceIdentifier ?? "")|\(s.originalVolume)|\(s.speakTranslation)"
    }
}

let watcher = LiveWatcher()

/// Saved sessions appear as resources; tell clients when the list changes (a session was
/// archived or deleted). Debounced, always on — it costs one directory watch.
final class SessionsWatcher {
    private let queue = DispatchQueue(label: "macdub-mcp.sessions")
    private var source: DispatchSourceFileSystemObject?
    private var pending = false
    private var lastIDs: Set<String> = []

    func start() {
        let dir = SessionStore.directory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        lastIDs = Set(SessionStore.list().map(\.id))
        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: queue)
        src.setEventHandler { [weak self] in
            guard let self, !self.pending else { return }
            self.pending = true
            self.queue.asyncAfter(deadline: .now() + .milliseconds(700)) {
                self.pending = false
                let ids = Set(SessionStore.list().map(\.id))
                if ids != self.lastIDs {
                    self.lastIDs = ids
                    send(["jsonrpc": "2.0", "method": "notifications/resources/list_changed"])
                }
            }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
    }
}

let sessionsWatcher = SessionsWatcher()

func ok(_ id: Any, _ result: Any) -> [String: Any] { ["jsonrpc": "2.0", "id": id, "result": result] }
func err(_ id: Any, _ code: Int, _ message: String) -> [String: Any] { ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]] }

/// Handles one JSON-RPC message. Returns the response, or nil for notifications.
func dispatch(_ message: [String: Any]) -> [String: Any]? {
    let method = message["method"] as? String ?? ""
    let params = message["params"] as? [String: Any] ?? [:]
    guard let id = message["id"] else {
        return nil // notifications (initialized, cancelled…) need no answer
    }

    switch method {
    case "initialize":
        return ok(id, [
            "protocolVersion": (params["protocolVersion"] as? String) ?? protocolVersion,
            "capabilities": ["tools": [:], "resources": ["subscribe": true, "listChanged": true], "prompts": [:]],
            "serverInfo": ["name": serverName, "version": serverVersion],
            "instructions": "MacDub dubs another app's audio in real time and keeps a transcript (original + translation). Use get_transcript (markdown) to summarise what was said, search_transcript to find something specific, list_sessions/get_session for earlier sessions, get_status to see whether it is running, and set_languages/set_voice/set_speak/set_original_volume to control the session. Subscribe to macdub://transcript to be notified as new sentences arrive.",
        ])
    case "ping":
        return ok(id, [:])
    case "tools/list":
        return ok(id, ["tools": tools.map { ["name": $0.name, "description": $0.description, "inputSchema": $0.schema] }])
    case "tools/call":
        let name = params["name"] as? String ?? ""
        let args = params["arguments"] as? [String: Any] ?? [:]
        guard let tool = tools.first(where: { $0.name == name }) else {
            return err(id, -32602, "Unknown tool '\(name)'")
        }
        do {
            let text = try tool.run(args)
            // Audio snippets travel as a separate audio content block.
            if let range = text.range(of: "\n<<audio:"), text.hasSuffix(">>") {
                let base64 = String(text[range.upperBound..<text.index(text.endIndex, offsetBy: -2)])
                let caption = String(text[..<range.lowerBound])
                return ok(id, ["content": [["type": "text", "text": caption],
                                           ["type": "audio", "data": base64, "mimeType": "audio/wav"]], "isError": false])
            }
            return ok(id, ["content": [["type": "text", "text": text]], "isError": false])
        } catch {
            return ok(id, ["content": [["type": "text", "text": error.localizedDescription]], "isError": true])
        }
    case "resources/list":
        let live = resources.map { ["uri": $0.uri, "name": $0.name, "description": $0.description, "mimeType": $0.mimeType] as [String: Any] }
        return ok(id, ["resources": live + sessionResources()])
    case "resources/templates/list":
        return ok(id, ["resourceTemplates": [
            ["uriTemplate": sessionTemplate, "name": "Saved session (Markdown)",
             "description": "A saved dubbing session by id (see list_sessions) as Markdown.", "mimeType": "text/markdown"],
            ["uriTemplate": sessionFormatTemplate, "name": "Saved session in a given format",
             "description": "A saved session as md, txt, srt or json.", "mimeType": "text/plain"],
        ]])
    case "resources/read":
        let uri = params["uri"] as? String ?? ""
        do {
            if let resource = resources.first(where: { $0.uri == uri }) {
                return ok(id, ["contents": [["uri": uri, "mimeType": resource.mimeType, "text": try resource.read()]]])
            } else if let (mimeType, text) = try readSessionResource(uri) {
                return ok(id, ["contents": [["uri": uri, "mimeType": mimeType, "text": text]]])
            }
            return err(id, -32002, "Unknown resource '\(uri)'")
        } catch {
            return err(id, -32603, error.localizedDescription)
        }
    case "resources/subscribe", "resources/unsubscribe":
        let uri = params["uri"] as? String ?? ""
        guard resources.contains(where: { $0.uri == uri }) else {
            return err(id, -32002, "Unknown resource '\(uri)'")
        }
        if method == "resources/subscribe" { watcher.subscribe(uri) } else { watcher.unsubscribe(uri) }
        return ok(id, [:])
    case "prompts/list":
        return ok(id, ["prompts": prompts.map { ["name": $0.name, "description": $0.description, "arguments": $0.arguments] }])
    case "prompts/get":
        let name = params["name"] as? String ?? ""
        let args = (params["arguments"] as? [String: String]) ?? [:]
        guard let prompt = prompts.first(where: { $0.name == name }) else {
            return err(id, -32602, "Unknown prompt '\(name)'")
        }
        do {
            return ok(id, ["description": prompt.description,
                           "messages": [["role": "user", "content": ["type": "text", "text": try prompt.build(args)]]]])
        } catch {
            return err(id, -32603, error.localizedDescription)
        }
    default:
        return err(id, -32601, "Method not found: \(method)")
    }
}

// MARK: - HTTP transport (MCP Streamable HTTP, localhost only)
//
//   macdub-mcp --http [port] [--token SECRET]
//
// POST /mcp  → one JSON-RPC message (or a batch) in, JSON out (202 for notifications only).
// GET  /mcp  → text/event-stream carrying server notifications (resource updates, list changes).
// Binds to 127.0.0.1; rejects non-localhost Origin headers (DNS-rebinding guard); optional
// bearer token. Put it behind a tunnel/reverse proxy with TLS for remote assistants.

import Network

final class HTTPTransport {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "macdub-mcp.http")
    private var streams: [ObjectIdentifier: NWConnection] = [:]
    private let token: String?
    private let port: UInt16

    init(port: UInt16, token: String?) throws {
        self.port = port
        self.token = token
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        listener = try NWListener(using: params)
    }

    func start() {
        listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        listener.stateUpdateHandler = { state in
            if case .failed(let e) = state { FileHandle.standardError.write("listener failed: \(e)\n".data(using: .utf8)!); exit(1) }
        }
        listener.start(queue: queue)
        notificationSink = { [weak self] object in self?.broadcast(object) }
        FileHandle.standardError.write("macdub-mcp: Streamable HTTP on http://127.0.0.1:\(port)/mcp\n".data(using: .utf8)!)
    }

    private let verbose = ProcessInfo.processInfo.environment["MACDUB_MCP_DEBUG"] != nil

    private func log(_ s: String) {
        if verbose { FileHandle.standardError.write("macdub-mcp: \(s)\n".data(using: .utf8)!) }
    }

    private func accept(_ conn: NWConnection) {
        log("accept \(conn.endpoint)")
        conn.stateUpdateHandler = { [weak self] state in self?.log("state \(state)") }
        conn.start(queue: queue)
        readRequest(conn, buffer: Data())
    }

    private func readRequest(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            self.log("received \(data?.count ?? 0) bytes (total \(buf.count)) complete=\(isComplete) error=\(String(describing: error))")
            if let headerEnd = buf.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buf[..<headerEnd.lowerBound], as: UTF8.self)
                let lines = head.components(separatedBy: "\r\n")
                let requestLine = lines.first?.split(separator: " ").map(String.init) ?? []
                var headers: [String: String] = [:]
                for line in lines.dropFirst() {
                    if let i = line.firstIndex(of: ":") {
                        headers[line[..<i].trimmingCharacters(in: .whitespaces).lowercased()] = line[line.index(after: i)...].trimmingCharacters(in: .whitespaces)
                    }
                }
                let length = Int(headers["content-length"] ?? "0") ?? 0
                let bodyStart = headerEnd.upperBound
                if buf.count - bodyStart < length, !isComplete, error == nil {
                    self.readRequest(conn, buffer: buf) // wait for the rest of the body
                    return
                }
                let body = buf[bodyStart..<min(buf.count, bodyStart + length)]
                self.route(conn, method: requestLine.first ?? "", path: requestLine.dropFirst().first ?? "/", headers: headers, body: Data(body))
            } else if isComplete || error != nil {
                conn.cancel()
            } else {
                self.readRequest(conn, buffer: buf)
            }
        }
    }

    private func route(_ conn: NWConnection, method: String, path: String, headers: [String: String], body: Data) {
        // DNS-rebinding guard: browsers send Origin; only localhost origins may talk to us.
        if let origin = headers["origin"], !(origin.contains("://127.0.0.1") || origin.contains("://localhost")) {
            respond(conn, status: 403, body: "forbidden origin"); return
        }
        if let token, headers["authorization"] != "Bearer \(token)" {
            respond(conn, status: 401, body: "unauthorized"); return
        }
        guard path == "/mcp" || path.hasPrefix("/mcp?") else {
            respond(conn, status: 404, body: "not found — use /mcp"); return
        }
        switch method {
        case "POST":
            guard let json = try? JSONSerialization.jsonObject(with: body) else {
                respond(conn, status: 400, body: "invalid JSON"); return
            }
            let messages = (json as? [[String: Any]]) ?? (json as? [String: Any]).map { [$0] } ?? []
            let responses = messages.compactMap(dispatch)
            if responses.isEmpty {
                respond(conn, status: 202, body: "")
            } else {
                let payload: Any = (json is [Any]) ? responses : responses[0]
                let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
                respond(conn, status: 200, contentType: "application/json", data: data)
            }
        case "GET":
            guard headers["accept"]?.contains("text/event-stream") == true else {
                respond(conn, status: 405, body: "GET /mcp needs Accept: text/event-stream"); return
            }
            let head = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: keep-alive\r\n\r\n: connected\n\n"
            conn.send(content: head.data(using: .utf8), completion: .contentProcessed { _ in })
            streams[ObjectIdentifier(conn)] = conn
            conn.stateUpdateHandler = { [weak self] state in
                if case .cancelled = state { self?.streams[ObjectIdentifier(conn)] = nil }
                if case .failed = state { self?.streams[ObjectIdentifier(conn)] = nil }
            }
            // Keep reading so we notice when the client goes away.
            drain(conn)
        case "DELETE":
            respond(conn, status: 200, body: "")
        default:
            respond(conn, status: 405, body: "method not allowed")
        }
    }

    private func drain(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] _, _, isComplete, error in
            if isComplete || error != nil { self?.streams[ObjectIdentifier(conn)] = nil; conn.cancel(); return }
            self?.drain(conn)
        }
    }

    private func broadcast(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object), let json = String(data: data, encoding: .utf8) else { return }
        let frame = "event: message\ndata: \(json)\n\n".data(using: .utf8)
        queue.async {
            for (_, conn) in self.streams { conn.send(content: frame, completion: .contentProcessed { _ in }) }
        }
    }

    private func respond(_ conn: NWConnection, status: Int, contentType: String = "text/plain", body: String) {
        respond(conn, status: status, contentType: contentType, data: body.data(using: .utf8) ?? Data())
    }

    private func respond(_ conn: NWConnection, status: Int, contentType: String, data: Data) {
        let reason = [200: "OK", 202: "Accepted", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed"][status] ?? "OK"
        var head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(contentType)\r\nContent-Length: \(data.count)\r\nConnection: close\r\n\r\n"
        head.reserveCapacity(head.count + data.count)
        var payload = head.data(using: .utf8)!
        payload.append(data)
        conn.send(content: payload, completion: .contentProcessed { _ in conn.cancel() })
    }
}

// MARK: - Main

setvbuf(stdout, nil, _IOLBF, 0)
sessionsWatcher.start()

let cli = CommandLine.arguments
// Kept alive for the whole process: the listener's handlers only hold weak references.
nonisolated(unsafe) var httpTransport: HTTPTransport?
if let i = cli.firstIndex(of: "--http") {
    let port = UInt16(cli.count > i + 1 ? cli[i + 1] : "") ?? 8765
    let token = cli.firstIndex(of: "--token").flatMap { cli.count > $0 + 1 ? cli[$0 + 1] : nil }
        ?? ProcessInfo.processInfo.environment["MACDUB_MCP_TOKEN"]
    do {
        httpTransport = try HTTPTransport(port: port, token: token)
        httpTransport?.start()
    } catch {
        FileHandle.standardError.write("cannot listen on \(port): \(error)\n".data(using: .utf8)!)
        exit(1)
    }
    dispatchMain()
} else {
    while let line = readLine(strippingNewline: true) {
        guard !line.isEmpty, let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
        if let response = dispatch(object) { writeStdout(response) }
    }
}
