import Foundation

/// Parsers for the machine-readable output of the assistant CLIs used for summaries.
/// Both return nil when the output isn't in the expected shape, so callers can fall back to
/// the raw text and `LocalLLM.estimateTokens`.
public enum AssistantOutput {
    public struct Parsed: Equatable, Sendable {
        public var text: String
        public var inputTokens: Int?
        public var outputTokens: Int?
        public var costUSD: Double?
        /// The CLI reported a failure; `text` holds its message.
        public var isError: Bool

        public init(text: String, inputTokens: Int? = nil, outputTokens: Int? = nil, costUSD: Double? = nil, isError: Bool = false) {
            self.text = text
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
            self.costUSD = costUSD
            self.isError = isError
        }
    }

    /// `claude -p --output-format json`: one JSON object with `result`, `usage` and
    /// `total_cost_usd`. Input tokens include prompt-cache reads and writes. Other lines (stderr
    /// is merged in) are skipped; the last JSON object wins.
    public static func claudeCode(_ output: String) -> Parsed? {
        for json in jsonLines(output).reversed() {
            guard let text = json["result"] as? String else { continue }
            let usage = json["usage"] as? [String: Any] ?? [:]
            let input = ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"]
                .compactMap { int(usage[$0]) }.reduce(0, +)
            return Parsed(text: text,
                          inputTokens: usage.isEmpty ? nil : input,
                          outputTokens: int(usage["output_tokens"]),
                          costUSD: json["total_cost_usd"] as? Double,
                          isError: json["is_error"] as? Bool == true)
        }
        return nil
    }

    /// `codex exec --json`: JSON Lines events (codex-rs/exec/src/exec_events.rs). The reply is the
    /// last `item.completed` whose item is an `agent_message`; tokens come from `turn.completed`
    /// `usage` (`input_tokens` already includes `cached_input_tokens`, `output_tokens` the
    /// reasoning tokens), summed over turns. `turn.failed` / `error` events become an error.
    public static func codexExec(_ output: String) -> Parsed? {
        var text: String?
        var input: Int?
        var outputTokens: Int?
        var failure: String?
        for json in jsonLines(output) {
            switch json["type"] as? String {
            case "item.completed":
                if let item = json["item"] as? [String: Any], item["type"] as? String == "agent_message",
                   let message = item["text"] as? String {
                    text = message
                }
            case "turn.completed":
                if let usage = json["usage"] as? [String: Any] {
                    if let i = int(usage["input_tokens"]) { input = (input ?? 0) + i }
                    if let o = int(usage["output_tokens"]) { outputTokens = (outputTokens ?? 0) + o }
                }
            case "turn.failed":
                failure = (json["error"] as? [String: Any])?["message"] as? String ?? "Codex failed"
            case "error":
                failure = json["message"] as? String ?? "Codex failed"
            default:
                break
            }
        }
        if let text { return Parsed(text: text, inputTokens: input, outputTokens: outputTokens) }
        if let failure { return Parsed(text: failure, isError: true) }
        return nil
    }

    private static func jsonLines(_ output: String) -> [[String: Any]] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("{") else { return nil }
            return try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) as? [String: Any]
        }
    }

    private static func int(_ value: Any?) -> Int? {
        (value as? NSNumber)?.intValue
    }
}
