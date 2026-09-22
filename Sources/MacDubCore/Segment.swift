import Foundation

/// A chunk of recognized speech, translated once the model answers.
public struct Segment: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public let original: String
    public var translated: String?
    public var failed = false
    /// Translated but not spoken because the voice had fallen too far behind.
    public var skipped = false
    /// When the sentence was cut from the transcript (≈ when the speaker finished it).
    public let recognizedAt: Date
    public var translatedAt: Date?
    public var spokenAt: Date?
    /// Speaker index when a diarization source assigns one (none of Apple's frameworks do
    /// today; the field is here so voices-per-speaker can be wired without touching the model).
    public var speaker: Int?

    public init(original: String, translated: String? = nil, recognizedAt: Date = Date()) {
        self.original = original
        self.translated = translated
        self.recognizedAt = recognizedAt
    }

    public var translationLatency: TimeInterval? { translatedAt.map { $0.timeIntervalSince(recognizedAt) } }
    public var speechLatency: TimeInterval? { spokenAt.map { $0.timeIntervalSince(recognizedAt) } }
}
