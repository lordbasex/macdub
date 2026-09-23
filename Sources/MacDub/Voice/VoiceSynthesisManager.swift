import MacDubCore
import Foundation
import AVFAudio

/// Stage 3 of the pipeline: speaks translated segments with a system voice.
///
/// `AVSpeechSynthesizer` already serializes utterances, so sentences never overlap. What we add
/// is backlog management: when the dub falls behind the video, utterances are spoken faster
/// (up to `catchUpBoost`), and beyond `maxBacklog` the oldest queued sentences are skipped.
final class VoiceSynthesisManager: NSObject {
    /// Voice identifier (`AVSpeechSynthesisVoice.identifier`). Falls back to `language`.
    var voiceIdentifier: String?
    /// BCP-47 language used when `voiceIdentifier` is nil or invalid.
    var language = "es-ES"
    /// Base speech rate, `AVSpeechUtteranceMinimumSpeechRate`…`AVSpeechUtteranceMaximumSpeechRate`.
    var rate: Float = AVSpeechUtteranceDefaultSpeechRate
    var volume: Float = 1
    /// Maximum queued utterances before the oldest are dropped. 0 disables dropping.
    var maxBacklog = 5
    /// Extra rate per queued utterance while catching up (0.15 = 15 % faster per pending sentence),
    /// capped at `maxCatchUpFactor` × base rate so it stays intelligible.
    var catchUpBoost: Float = 0.10
    var maxCatchUpFactor: Float = 1.4

    /// Number of utterances queued or speaking. Called on the main thread.
    var onBacklogChanged: ((Int) -> Void)?
    /// Text currently being spoken (nil when idle). Called on the main thread.
    var onSpeaking: ((String?) -> Void)?
    /// The segment whose utterance just started playing. Called on the main thread.
    var onSegmentStarted: ((UUID) -> Void)?
    /// The word (character range of the spoken text) about to be pronounced, per segment.
    /// `nil` range when the utterance ends. Called on the main thread.
    var onWordRange: ((UUID, NSRange?) -> Void)?

    private let synthesizer = AVSpeechSynthesizer()
    private var queued: [AVSpeechUtterance] = []
    private var segmentIDs: [ObjectIdentifier: UUID] = [:]

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    // MARK: Voices

    static func voices(forLanguageCode code: String) -> [AVSpeechSynthesisVoice] {
        let prefix = code.lowercased()
        // Best first: premium > enhanced > compact; within a tier, Apple's regular voices (Mónica,
        // Paulina…) before the Eloquence novelty voices (Eddy, Flo, Grandma…).
        func isNovelty(_ v: AVSpeechSynthesisVoice) -> Bool { v.identifier.contains(".eloquence.") }
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.lowercased().hasPrefix(prefix) }
            .sorted {
                if $0.quality != $1.quality { return $0.quality.rawValue > $1.quality.rawValue }
                if isNovelty($0) != isNovelty($1) { return !isNovelty($0) }
                if $0.language != $1.language { return $0.language < $1.language }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
    }

    static func qualityLabel(_ q: AVSpeechSynthesisVoiceQuality) -> String {
        switch q {
        case .premium: return "Premium"
        case .enhanced: return "Enhanced"
        default: return "Compact"
        }
    }

    /// Coloured dot for menus (emoji survive NSMenu titles; SwiftUI colours don't):
    /// 🟢 premium · 🟡 enhanced · ⚪ compact · ⚫ novelty (Eloquence).
    static func qualityDot(_ v: AVSpeechSynthesisVoice) -> String {
        if v.identifier.contains(".eloquence.") { return "⚫" }
        switch v.quality {
        case .premium: return "🟢"
        case .enhanced: return "🟡"
        default: return "⚪"
        }
    }

    /// "🟡 Paulina (mejorada) — es-MX". The dot is the quality; macOS already names Enhanced and
    /// Premium voices in the user's language, so an English "· Enhanced" only repeated it (and
    /// was what got truncated in narrow pickers). `qualityLabel` stays for the MCP status.
    static func menuTitle(for v: AVSpeechSynthesisVoice) -> String {
        "\(qualityDot(v)) \(v.name) — \(v.language)"
    }

    // MARK: Speaking

    var backlog: Int { queued.count }

    /// Speech rate for a new utterance given how many are already queued (see `SpeechRate.catchUp`).
    static func catchUpRate(base: Float, backlog: Int, boost: Float, maxFactor: Float) -> Float {
        SpeechRate.catchUp(base: base, backlog: backlog, boost: boost, maxFactor: maxFactor,
                           maximum: AVSpeechUtteranceMaximumSpeechRate)
    }

    func speak(_ text: String, segmentID: UUID? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if maxBacklog > 0, queued.count >= maxBacklog {
            // Too far behind: drop everything not yet started, keep only the most recent.
            Log.voice.notice("Backlog \(self.queued.count) ≥ \(self.maxBacklog); skipping queued sentences")
            skipBacklog()
        }

        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.voice = resolvedVoice()
        utterance.volume = volume
        utterance.postUtteranceDelay = 0.05
        utterance.rate = Self.catchUpRate(base: rate, backlog: queued.count, boost: catchUpBoost, maxFactor: maxCatchUpFactor)

        if let segmentID { segmentIDs[ObjectIdentifier(utterance)] = segmentID }
        queued.append(utterance)
        notifyBacklog()
        synthesizer.speak(utterance)
    }

    /// Cancel queued utterances but let the current one finish.
    func skipBacklog() {
        guard queued.count > 1 else { return }
        let current = synthesizer.isSpeaking ? queued.first : nil
        synthesizer.stopSpeaking(at: .word)
        queued.removeAll()
        if let current { queued.append(current) }
        notifyBacklog()
    }

    /// Holds the current utterance (History playback paused). `resume()` continues it.
    func pause() {
        guard synthesizer.isSpeaking, !synthesizer.isPaused else { return }
        synthesizer.pauseSpeaking(at: .word)
    }

    func resume() {
        guard synthesizer.isPaused else { return }
        synthesizer.continueSpeaking()
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        queued.removeAll()
        notifyBacklog()
        DispatchQueue.main.async { self.onSpeaking?(nil) }
    }

    private func resolvedVoice() -> AVSpeechSynthesisVoice? {
        if let id = voiceIdentifier, let v = AVSpeechSynthesisVoice(identifier: id) { return v }
        return AVSpeechSynthesisVoice(language: language)
            ?? Self.voices(forLanguageCode: String(language.prefix(2))).first
    }

    private func notifyBacklog() {
        let n = queued.count
        DispatchQueue.main.async { self.onBacklogChanged?(n) }
    }
}

extension VoiceSynthesisManager: AVSpeechSynthesizerDelegate {
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        let text = utterance.speechString
        let id = segmentIDs[ObjectIdentifier(utterance)]
        DispatchQueue.main.async {
            self.onSpeaking?(text)
            if let id { self.onSegmentStarted?(id) }
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange,
                           utterance: AVSpeechUtterance) {
        guard let id = segmentIDs[ObjectIdentifier(utterance)] else { return }
        DispatchQueue.main.async { self.onWordRange?(id, characterRange) }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        if let id = segmentIDs[ObjectIdentifier(utterance)] {
            DispatchQueue.main.async { self.onWordRange?(id, nil) }
        }
        dequeue(utterance)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        dequeue(utterance)
    }

    private func dequeue(_ utterance: AVSpeechUtterance) {
        queued.removeAll { $0 === utterance }
        segmentIDs[ObjectIdentifier(utterance)] = nil
        notifyBacklog()
        if queued.isEmpty {
            DispatchQueue.main.async { self.onSpeaking?(nil) }
        }
    }
}
