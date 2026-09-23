import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Local model servers and Apple's on-device model, shared by the app's "Summarize with…"
/// feature and the MCP server's `summarize_transcript` tool. Everything here is synchronous
/// (call off the main thread) and network-local: Ollama on :11434, LM Studio on :1234.
public enum LocalLLM {
    public enum Provider: String, CaseIterable {
        case apple, ollama, lmstudio
    }

    public struct Error: Swift.Error, LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
        public init(_ message: String) { self.message = message }
    }

    public static let ollamaBase = URL(string: "http://127.0.0.1:11434")!
    public static let lmStudioBase = URL(string: "http://127.0.0.1:1234")!

    // MARK: Discovery

    public static func ollamaModels() -> [String] {
        guard let json = try? get(ollamaBase.appendingPathComponent("api/tags")) else { return [] }
        return (json["models"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
    }

    public static func lmStudioModels() -> [String] {
        guard let json = try? get(lmStudioBase.appendingPathComponent("v1/models")) else { return [] }
        return (json["data"] as? [[String: Any]])?.compactMap { $0["id"] as? String } ?? []
    }

    public static var appleAvailable: Bool { appleStatus == .available }

    /// Why the on-device Apple Intelligence model can or cannot be used on this Mac.
    public enum AppleIntelligenceStatus: Sendable {
        case available
        case notEnabled          // eligible Mac, Apple Intelligence off in System Settings
        case deviceNotEligible   // e.g. Intel Macs
        case modelNotReady       // still downloading / preparing
        case requiresMacOS26
        case notInBuild          // built with an SDK without FoundationModels
        case unknown
    }

    public static var appleStatus: AppleIntelligenceStatus {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return .available
            case .unavailable(.appleIntelligenceNotEnabled): return .notEnabled
            case .unavailable(.deviceNotEligible): return .deviceNotEligible
            case .unavailable(.modelNotReady): return .modelNotReady
            default: return .unknown
            }
        }
        return .requiresMacOS26
        #else
        return .notInBuild
        #endif
    }

    /// Providers usable right now, in preference order (on-device first).
    public static func availableProviders() -> [(Provider, [String])] {
        var out: [(Provider, [String])] = []
        if appleAvailable { out.append((.apple, [])) }
        let ollama = ollamaModels()
        if !ollama.isEmpty { out.append((.ollama, ollama)) }
        let lm = lmStudioModels()
        if !lm.isEmpty { out.append((.lmstudio, lm)) }
        return out
    }

    // MARK: Prompts

    public static func summaryInstructions(language: String) -> String {
        """
        You are given the transcript of something the user just watched or listened to (original text and its \
        machine translation, with timestamps). Write a concise summary in the language with code "\(language)": \
        1) three-sentence overview, 2) key points as bullets, 3) any decisions, numbers, names or action items \
        worth remembering. Do not translate the transcript back; do not mention that it was machine-generated.
        """
    }

    // MARK: Chat

    /// A reply plus the token counts the provider reported (nil when it reports none).
    public struct ChatResult: Sendable {
        public var text: String
        public var inputTokens: Int?
        public var outputTokens: Int?
        /// True when the counts are `estimateTokens` guesses rather than the provider's own.
        public var tokensEstimated: Bool

        public init(text: String, inputTokens: Int? = nil, outputTokens: Int? = nil, tokensEstimated: Bool = false) {
            self.text = text
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
            self.tokensEstimated = tokensEstimated
        }

        /// Fills missing counts with estimates.
        public func estimatingMissing(input: String) -> ChatResult {
            guard inputTokens == nil || outputTokens == nil else { return self }
            return ChatResult(text: text,
                              inputTokens: inputTokens ?? LocalLLM.estimateTokens(input),
                              outputTokens: outputTokens ?? LocalLLM.estimateTokens(text),
                              tokensEstimated: true)
        }
    }

    /// Rough, provider-independent token estimate (~4 characters per token).
    public static func estimateTokens(_ text: String) -> Int {
        max(1, (text.count + 3) / 4)
    }

    public static func chat(provider: Provider, model: String?, system: String, user: String) throws -> String {
        try chatWithUsage(provider: provider, model: model, system: system, user: user).text
    }

    public static func chatWithUsage(provider: Provider, model: String?, system: String, user: String) throws -> ChatResult {
        switch provider {
        case .apple:
            return try appleRespond(system: system, user: user)
        case .ollama:
            guard let model else { throw Error("Ollama needs a model name (see ollamaModels)") }
            let json = try post(ollamaBase.appendingPathComponent("api/chat"), body: [
                "model": model, "stream": false,
                "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
            ])
            if let text = (json["message"] as? [String: Any])?["content"] as? String {
                return ChatResult(text: text, inputTokens: json["prompt_eval_count"] as? Int, outputTokens: json["eval_count"] as? Int)
                    .estimatingMissing(input: system + user)
            }
            throw Error(errorMessage(json))
        case .lmstudio:
            guard let model else { throw Error("LM Studio needs a model id (see lmStudioModels)") }
            let json = try post(lmStudioBase.appendingPathComponent("v1/chat/completions"), body: [
                "model": model, "stream": false,
                "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
            ])
            let choices = json["choices"] as? [[String: Any]]
            if let text = (choices?.first?["message"] as? [String: Any])?["content"] as? String {
                let usage = json["usage"] as? [String: Any]
                return ChatResult(text: text, inputTokens: usage?["prompt_tokens"] as? Int, outputTokens: usage?["completion_tokens"] as? Int)
                    .estimatingMissing(input: system + user)
            }
            throw Error(errorMessage(json))
        }
    }

    private static func appleRespond(system: String, user: String) throws -> ChatResult {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let semaphore = DispatchSemaphore(value: 0)
            var result: Result<ChatResult, Swift.Error> = .failure(Error("Apple Intelligence is not available"))
            Task {
                do {
                    let session = LanguageModelSession(instructions: system)
                    // The on-device context window is small; keep the tail if the text is long.
                    let text = user.count > 12_000 ? String(user.suffix(12_000)) : user
                    let response = try await session.respond(to: text)
                    var reply = ChatResult(text: response.content)
                    // The model's own tokenizer: macOS 26.4 SDK (Swift 6.3 toolchains) and OS.
                    #if compiler(>=6.3)
                    if #available(macOS 26.4, *) {
                        let model = SystemLanguageModel.default
                        reply.inputTokens = try? await model.tokenCount(for: system + "\n" + text)
                        reply.outputTokens = try? await model.tokenCount(for: response.content)
                    }
                    #endif
                    result = .success(reply.estimatingMissing(input: system + text))
                } catch {
                    result = .failure(error)
                }
                semaphore.signal()
            }
            semaphore.wait()
            return try result.get()
        }
        #endif
        throw Error("Apple Intelligence needs macOS 26 on Apple Intelligence hardware")
    }

    // MARK: HTTP

    private static func get(_ url: URL) throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        return try perform(request)
    }

    private static func post(_ url: URL, body: [String: Any]) throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try perform(request)
    }

    private static func perform(_ request: URLRequest) throws -> [String: Any] {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<[String: Any], Swift.Error> = .failure(Error("No response"))
        URLSession.shared.dataTask(with: request) { data, _, error in
            defer { semaphore.signal() }
            if let error { result = .failure(error); return }
            guard let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                result = .failure(Error("Unexpected response"))
                return
            }
            result = .success(json)
        }.resume()
        semaphore.wait()
        return try result.get()
    }

    private static func errorMessage(_ json: [String: Any]) -> String {
        (json["error"] as? String) ?? ((json["error"] as? [String: Any])?["message"] as? String) ?? "Unexpected response"
    }
}
