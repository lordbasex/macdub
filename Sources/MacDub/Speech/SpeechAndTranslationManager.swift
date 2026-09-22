import MacDubCore
import Foundation
import Speech
import AVFAudio

/// Stage 2 of the pipeline: on-device speech recognition + on-device translation.
///
/// A `RecognitionEngine` streams a continuously revised transcript; `TranscriptSegmenter` cuts
/// it into chunks; each chunk goes to `TranslationBridge`. Runs are rotated on silence, on
/// engine errors and (for `SFSpeechRecognizer`) after `maxTaskDuration`, because a single task
/// accumulates an ever-growing transcript and, on some macOS versions, ends by itself.
final class SpeechAndTranslationManager: NSObject, @unchecked Sendable {
    // All mutable state is confined to `queue`; callbacks are invoked on that same queue.
    var onPartial: ((String) -> Void)?
    var onSegmentRecognized: ((Segment) -> Void)?
    var onSegmentTranslated: ((Segment) -> Void)?
    var onFatalError: ((Error) -> Void)?

    /// Emit uncommitted text after this much time without new partial results.
    var silenceFlushInterval: TimeInterval = 0.9
    /// Rotate the recognition run after this long (engines that need it), regardless of speech.
    var maxTaskDuration: TimeInterval = 45

    /// Fired (on the manager queue) when the engine had to be swapped, e.g. SpeechAnalyzer
    /// failed before producing anything and SFSpeechRecognizer took over.
    var onEngineChanged: ((RecognitionEngineKind) -> Void)?

    private let translator: TranslationBridge
    private let queue = DispatchQueue(label: "com.lordbasex.MacDub.speech", qos: .userInitiated)
    private var engine: RecognitionEngine?
    private(set) var engineKind: RecognitionEngineKind = .legacy
    private var sourceLocale = Locale(identifier: "en-US")
    private var receivedTranscript = false
    private var segmenter = TranscriptSegmenter()
    private var timer: DispatchSourceTimer?
    private var isRunning = false
    private var recentFailures: [Date] = []

    init(translator: TranslationBridge) {
        self.translator = translator
        super.init()
    }

    // MARK: Authorization & capabilities

    static func authorizationStatus() -> SFSpeechRecognizerAuthorizationStatus {
        SFSpeechRecognizer.authorizationStatus()
    }

    static func requestAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) }
        }
    }

    static func allLocales() -> [Locale] {
        SFSpeechRecognizer.supportedLocales()
            .sorted { displayName($0).localizedCaseInsensitiveCompare(displayName($1)) == .orderedAscending }
    }

    static func supportsOnDevice(_ locale: Locale) -> Bool {
        SFSpeechEngine.supportsOnDevice(locale)
    }

    static func displayName(_ locale: Locale) -> String {
        let name = Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
        return "\(name) (\(locale.identifier))"
    }

    // MARK: Lifecycle

    func start(sourceLocale: Locale, engineKind requested: RecognitionEngineKind = .auto) throws {
        var kind = requested.resolved
        var engine: RecognitionEngine
        do {
            engine = try makeEngine(kind, locale: sourceLocale)
        } catch where kind == .analyzer {
            // The new engine could not even start (no assets, unsupported locale…): use the proven one.
            Log.speech.notice("SpeechAnalyzer unavailable (\(error.localizedDescription, privacy: .public)); using SFSpeechRecognizer")
            kind = .legacy
            engine = try makeEngine(.legacy, locale: sourceLocale)
        }

        queue.sync {
            self.engine = engine
            self.engineKind = kind
            self.sourceLocale = sourceLocale
            self.receivedTranscript = false
            self.segmenter = TranscriptSegmenter()
            self.segmenter.silenceFlushInterval = self.silenceFlushInterval
            self.isRunning = true
            self.recentFailures.removeAll()
            self.startTimer()
        }
        Log.speech.info("Recognition started for \(sourceLocale.identifier, privacy: .public) (\(kind.rawValue, privacy: .public))")
    }

    private func makeEngine(_ kind: RecognitionEngineKind, locale: Locale) throws -> RecognitionEngine {
        var engine: RecognitionEngine = SFSpeechEngine()
        #if compiler(>=6.2)
        if kind == .analyzer, #available(macOS 26.0, *) {
            engine = SpeechAnalyzerEngine()
        }
        #endif
        engine.onTranscript = { [weak self, weak engine] text, isFinal in
            self?.queue.async {
                guard let self, self.engine === engine else { return }
                self.handleTranscript(text, isFinal: isFinal)
            }
        }
        engine.onRunEnded = { [weak self, weak engine] error in
            self?.queue.async {
                guard let self, self.engine === engine else { return }
                self.handleRunEnded(error)
            }
        }
        try engine.start(locale: locale)
        return engine
    }

    /// SpeechAnalyzer failed at runtime before delivering any text: swap to SFSpeechRecognizer
    /// without dropping the session. Returns false when no fallback applies.
    private func fallBackToLegacyIfPossible() -> Bool {
        guard engineKind == .analyzer, !receivedTranscript else { return false }
        engine?.stop()
        do {
            engine = try makeEngine(.legacy, locale: sourceLocale)
            engineKind = .legacy
            recentFailures.removeAll()
            segmenter.reset()
            Log.speech.notice("SpeechAnalyzer failed at runtime; switched to SFSpeechRecognizer")
            onEngineChanged?(.legacy)
            return true
        } catch {
            return false
        }
    }

    func stop() {
        queue.sync {
            self.isRunning = false
            self.timer?.cancel()
            self.timer = nil
            if let rest = self.segmenter.flush() { self.emit(rest) }
            self.onPartial?("")
            self.engine?.stop()
            self.engine = nil
        }
        Task { @MainActor in translator.cancelPending() }
        Log.speech.info("Recognition stopped")
    }

    /// Feed captured audio. Safe to call from any thread.
    func append(_ buffer: AVAudioPCMBuffer) {
        engine?.append(buffer)
    }

    // MARK: Engine events (on queue)

    private func handleTranscript(_ text: String, isFinal: Bool) {
        guard isRunning else { return }
        if !text.isEmpty { receivedTranscript = true }
        for chunk in segmenter.update(transcript: text) { emit(chunk) }
        onPartial?(segmenter.uncommitted)
        if isFinal { rotate(reason: "final") }
    }

    private func handleRunEnded(_ error: Error?) {
        guard isRunning else { return }
        if let error {
            let ns = error as NSError
            // 1110 "No speech detected" and cancellations are routine; anything repeated
            // in a short window is treated as fatal.
            Log.speech.debug("Recognition run error \(ns.domain, privacy: .public)/\(ns.code): \(ns.localizedDescription, privacy: .public)")
            recentFailures.append(Date())
            recentFailures.removeAll { $0.timeIntervalSinceNow < -15 }
            // The experimental engine dying before it said anything → fall back immediately.
            if engineKind == .analyzer, fallBackToLegacyIfPossible() { return }
            if recentFailures.count > 6 {
                isRunning = false
                onFatalError?(MacDubError.speechRecognizerUnavailable(ns.localizedDescription))
                return
            }
        }
        rotate(reason: error == nil ? "run ended" : "error")
    }

    /// Emit whatever is pending, then begin a fresh run.
    private func rotate(reason: String) {
        guard isRunning else { return }
        if let rest = segmenter.flush() { emit(rest) }
        onPartial?("")
        segmenter.reset()
        engine?.restart()
        Log.speech.debug("Rotated recognition run (\(reason, privacy: .public))")
    }

    // MARK: Emission

    private func emit(_ text: String) {
        var segment = Segment(original: text)
        Log.speech.info("Segment: \(text, privacy: .public)")
        onSegmentRecognized?(segment)

        Task { [translator, queue] in
            do {
                let translated = try await translator.translate(text)
                segment.translated = translated
                segment.translatedAt = Date()
            } catch {
                segment.failed = true
            }
            queue.async { [weak self] in self?.onSegmentTranslated?(segment) }
        }
    }

    // MARK: Timer (silence flush, time-based cut, run rotation)

    private func startTimer() {
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.2, repeating: 0.2)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    private func tick() {
        guard isRunning, let engine else { return }
        let now = Date()
        if segmenter.shouldFlushForSilence(now: now) {
            rotate(reason: "silence")
        } else if let chunk = segmenter.cutByTime(now: now) {
            emit(chunk)
            onPartial?(segmenter.uncommitted)
        } else if engine.needsPeriodicRestart, now.timeIntervalSince(segmenter.runStartedAt) > maxTaskDuration {
            rotate(reason: "max duration")
        }
    }
}
