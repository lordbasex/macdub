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

    public static var appleAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability { return true }
        }
        #endif
        return false
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

    public static func chat(provider: Provider, model: String?, system: String, user: String) throws -> String {
        switch provider {
        case .apple:
            return try appleRespond(system: system, user: user)
        case .ollama:
            guard let model else { throw Error("Ollama needs a model name (see ollamaModels)") }
            let json = try post(ollamaBase.appendingPathComponent("api/chat"), body: [
                "model": model, "stream": false,
                "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
            ])
            if let text = (json["message"] as? [String: Any])?["content"] as? String { return text }
            throw Error(errorMessage(json))
        case .lmstudio:
            guard let model else { throw Error("LM Studio needs a model id (see lmStudioModels)") }
            let json = try post(lmStudioBase.appendingPathComponent("v1/chat/completions"), body: [
                "model": model, "stream": false,
                "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
            ])
            let choices = json["choices"] as? [[String: Any]]
            if let text = (choices?.first?["message"] as? [String: Any])?["content"] as? String { return text }
            throw Error(errorMessage(json))
        }
    }

    private static func appleRespond(system: String, user: String) throws -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let semaphore = DispatchSemaphore(value: 0)
            var result: Result<String, Swift.Error> = .failure(Error("Apple Intelligence is not available"))
            Task {
                do {
                    let session = LanguageModelSession(instructions: system)
                    // The on-device context window is small; keep the tail if the text is long.
                    let text = user.count > 12_000 ? String(user.suffix(12_000)) : user
                    let response = try await session.respond(to: text)
                    result = .success(response.content)
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
