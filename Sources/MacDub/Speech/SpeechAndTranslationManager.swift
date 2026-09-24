import MacDubCore
import Foundation
import Speech
import AVFAudio
import Accelerate

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
    /// Every cumulative transcript the engine reports, before segmentation (benchmark/debugging).
    var onRawTranscript: ((_ text: String, _ isFinal: Bool) -> Void)?

    /// Emit uncommitted text after this much time without new partial results.
    var silenceFlushInterval: TimeInterval = 0.9
    /// Rotate the recognition run after this long (engines that need it), regardless of speech.
    var maxTaskDuration: TimeInterval = 45

    /// Fired (on the manager queue) when the engine had to be swapped, e.g. SpeechAnalyzer
    /// failed before producing anything and SFSpeechRecognizer took over.
    var onEngineChanged: ((RecognitionEngineKind) -> Void)?

    private let translator: TranslationBridge
    private let queue = DispatchQueue(label: "com.lordbasex.MacDub.speech", qos: .userInitiated)
    private var engine: RecognitionEngine? {
        didSet { feedLock.lock(); feed = engine; feedLock.unlock() }
    }
    /// `engine` for `append`, which runs on the capture thread while `engine` is replaced on
    /// `queue` (fallback to SFSpeechRecognizer, stop): reading it unlocked was a data race.
    private var feed: RecognitionEngine?
    private let feedLock = NSLock()
    private(set) var engineKind: RecognitionEngineKind = .legacy
    private var sourceLocale = Locale(identifier: "en-US")
    private var receivedTranscript = false
    private var segmenter = TranscriptSegmenter()
    private var timer: DispatchSourceTimer?
    private var isRunning = false
    private var recentFailures: [Date] = []
    /// Runs the engine is still finishing after a rotation (`finishesPreviousRun`), oldest first,
    /// each with the segmenter state it had: their last words come out before anything newer.
    private var finishingRuns: [TranscriptSegmenter] = []
    /// Segments of the current run waiting for `finishingRuns` to end, in order.
    private var heldSegments: [String] = []
    /// Provisional text from engines that segment finals only, shown after the pending text.
    private var volatileTail = ""
    /// SpeechAnalyzer: segment finalized results only (see `SpeechAnalyzerEngine.segmentsFinalsOnly`).
    var analyzerFinalsOnly = true
    /// SpeechAnalyzer: longest wait for a final before volatile text goes out at a comma (nil:
    /// engine default, 0: never).
    var analyzerHardCap: TimeInterval?

    /// Last time a captured buffer had sound in it (peak above `soundThreshold`); written from
    /// the capture thread, read on `queue`.
    private var lastSoundAt = Date()
    private let soundLock = NSLock()
    private let soundThreshold: Float = 0.01  // ≈ −40 dBFS
    /// A pause in *text* is not a pause in speech: SpeechAnalyzer reports in bursts every few
    /// seconds, and SFSpeechRecognizer stalls for a second or more while people keep talking
    /// (rotating then lost the words being said). A silence cut also needs quiet *audio*, or
    /// text stalled this long.
    private var stallFlush: TimeInterval { engineKind == .analyzer ? 6 : 3 }

    /// SFSpeechRecognizer: end of the last pause in the audio (quiet for `pauseLength`), the
    /// kind speakers leave between sentences. Text that stops growing shortly after one is cut
    /// there without rotating (`pauseCut`); written from the capture thread, read on `queue`.
    private var lastPauseEnd: Date?
    private var quietSince: Date?
    private let pauseLength: TimeInterval = 0.25
    /// The periodic rotation happens at the first pause in the audio during the last this-long
    /// of `maxTaskDuration`, so it rarely lands mid-sentence (longer runs recognise worse).
    private let rotationWindow: TimeInterval = 15

    /// Live translation: when the speaker pauses this long, ask the engine to finalize what it
    /// heard (a conversation has a sentence and then silence; dubbing leaves it off). 0: never.
    var finalizeAfterPause: TimeInterval = 0
    /// Live translation: SpeechAnalyzer's `.fastResults` (see `SpeechAnalyzerEngine.fastResults`).
    var analyzerFastResults = false
    /// The pause `finalizeAtPause` was already asked for (once per pause).
    private var finalizedPause: Date?

    /// Whether the audio is in a pause right now (at least `pauseLength` quiet).
    private func audioQuiet(now: Date) -> Bool {
        soundLock.lock(); defer { soundLock.unlock() }
        return quietSince.map { now.timeIntervalSince($0) >= pauseLength } ?? false
    }

    /// Text stalled this long after an audio pause: emit it (sentence end, SFSpeechRecognizer).
    private let pauseCut: TimeInterval = 0.6

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
            self.volatileTail = ""
            self.segmenter = TranscriptSegmenter()
            self.finishingRuns.removeAll()
            self.heldSegments.removeAll()
            self.segmenter.silenceFlushInterval = self.silenceFlushInterval
            self.configureSegmenter(for: kind)
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
            let analyzer = SpeechAnalyzerEngine()
            analyzer.segmentsFinalsOnly = analyzerFinalsOnly
            if let cap = analyzerHardCap { analyzer.volatileHardCap = cap }
            analyzer.fastResults = analyzerFastResults
            engine = analyzer
        }
        #endif
        engine.onTranscript = { [weak self, weak engine] text, isFinal in
            self?.queue.async {
                guard let self, self.engine === engine else { return }
                self.handleTranscript(text, isFinal: isFinal)
            }
        }
        engine.onVolatile = { [weak self, weak engine] text in
            self?.queue.async {
                guard let self, self.engine === engine, self.isRunning else { return }
                self.volatileTail = text
                if !text.isEmpty { self.receivedTranscript = true }
                self.onPartial?(self.livePartial)
            }
        }
        engine.onPreviousRunEnded = { [weak self, weak engine] text in
            self?.queue.async {
                guard let self, self.engine === engine else { return }
                self.handlePreviousRunEnded(text)
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

    /// SFSpeechRecognizer punctuates little and provisionally: wait for text after a period, and
    /// let unpunctuated speech run longer before a time cut (audio pauses cut sentences sooner).
    private func configureSegmenter(for kind: RecognitionEngineKind) {
        guard kind == .legacy else { return }
        segmenter.terminatorNeedsFollowingText = true
        segmenter.maxPendingDuration = 8
        segmenter.clauseSplitCharacters = 160
        segmenter.maxSegmentCharacters = 240
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
            configureSegmenter(for: .legacy)
            finishingRuns.removeAll()
            releaseHeldSegments()
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
            self.finishingRuns.removeAll()
            self.releaseHeldSegments()
            self.volatileTail = ""
            self.onPartial?("")
            self.engine?.stop()
            self.engine = nil
        }
        Task { @MainActor in translator.cancelPending() }
        Log.speech.info("Recognition stopped")
    }

    /// Feed captured audio. Safe to call from any thread.
    func append(_ buffer: AVAudioPCMBuffer) {
        if let samples = buffer.floatChannelData, buffer.frameLength > 0 {
            var peak: Float = 0
            vDSP_maxmgv(samples[0], 1, &peak, vDSP_Length(buffer.frameLength))
            let now = Date()
            soundLock.lock()
            if peak > soundThreshold {
                lastSoundAt = now
                if let since = quietSince, now.timeIntervalSince(since) >= pauseLength { lastPauseEnd = now }
                quietSince = nil
            } else if quietSince == nil {
                quietSince = now
            }
            soundLock.unlock()
        }
        feedLock.lock(); let target = feed; feedLock.unlock()
        target?.append(buffer)
    }

    /// Whether a pause in the transcript really is a pause in speech (see `stallFlush`).
    private func silenceConfirmed(now: Date) -> Bool {
        soundLock.lock(); let quietFor = now.timeIntervalSince(lastSoundAt); soundLock.unlock()
        return quietFor >= silenceFlushInterval || now.timeIntervalSince(segmenter.lastUpdate) >= stallFlush
    }

    /// SFSpeechRecognizer: pending text stopped growing a moment after the speaker paused —
    /// most likely a sentence end the recognizer did not punctuate.
    private func pausedBeforeStall(now: Date) -> Bool {
        guard engineKind == .legacy, segmenter.hasPending,
              now.timeIntervalSince(segmenter.lastUpdate) >= pauseCut else { return false }
        soundLock.lock(); let pauseEnd = lastPauseEnd; soundLock.unlock()
        guard let pauseEnd else { return false }
        // The pause came before the last words arrived (recognition lags the audio), not long ago.
        return segmenter.lastUpdate.timeIntervalSince(pauseEnd) > -0.2 && now.timeIntervalSince(pauseEnd) < 2
    }

    // MARK: Engine events (on queue)

    private func handleTranscript(_ text: String, isFinal: Bool) {
        guard isRunning else { return }
        onRawTranscript?(text, isFinal)
        if !text.isEmpty { receivedTranscript = true }
        for chunk in segmenter.update(transcript: text) { emit(chunk) }
        onPartial?(livePartial)
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

    /// The oldest run being finished delivered its last transcript: emit the words it had not
    /// reported yet, then whatever the newer run produced meanwhile.
    private func handlePreviousRunEnded(_ text: String) {
        guard isRunning, !finishingRuns.isEmpty else { return }
        var run = finishingRuns.removeFirst()
        if !text.isEmpty {
            onRawTranscript?("<previous run: \(text)>", true)
            for chunk in run.update(transcript: text) { send(chunk) }
        }
        if let rest = run.flush() { send(rest) }
        if finishingRuns.isEmpty { releaseHeldSegments() }
    }

    private func releaseHeldSegments() {
        let held = heldSegments
        heldSegments.removeAll()
        for text in held { send(text) }
    }

    /// What is still being heard: pending text plus any provisional tail.
    private var livePartial: String {
        let pending = segmenter.uncommitted
        guard !volatileTail.isEmpty else { return pending }
        return pending.isEmpty ? volatileTail : pending + " " + volatileTail
    }

    /// Emit whatever is pending, then begin a fresh run.
    private func rotate(reason: String) {
        guard isRunning else { return }
        onRawTranscript?("<rotate: \(reason)>", false)
        var holdBack = false
        if engine?.finishesPreviousRun == true {
            // The run's last results are still coming: its final completes the last word.
            if let head = segmenter.flushKeepingLastWord() { emit(head) }
            finishingRuns.append(segmenter)
        } else if let rest = segmenter.flush() {
            // A provisional tail may end mid-word ("predomin"): keep its last word for the next
            // run instead of emitting a fragment, unless the text ends a sentence or clause.
            if engine?.tailIsVolatile == true, let last = rest.last, !".?!,;:".contains(last),
               let cut = rest.lastIndex(where: \.isWhitespace) {
                holdBack = true
                let head = rest[..<cut].trimmingCharacters(in: .whitespaces)
                if !head.isEmpty { emit(head) }
            } else if engine?.tailIsVolatile == true, let last = rest.last, !".?!,;:".contains(last) {
                holdBack = true  // a single provisional word: wait for it to finish
            } else {
                emit(rest)
            }
        }
        onPartial?("")
        segmenter.reset()
        engine?.restart(holdingBackLastWord: holdBack)
        Log.speech.debug("Rotated recognition run (\(reason, privacy: .public))")
    }

    // MARK: Emission

    /// Emit a segment of the current run, after the last words of any run still finishing.
    private func emit(_ text: String) {
        if finishingRuns.isEmpty { send(text) } else { heldSegments.append(text) }
    }

    private func send(_ text: String) {
        var segment = Segment(original: text)
        Log.speech.info("Segment: \(text, privacy: .public)")
        onSegmentRecognized?(segment)

        Task { [weak self, translator, queue] in
            do {
                let translated = try await translator.translate(text)
                segment.translated = translated
                segment.translatedAt = Date()
            } catch {
                segment.failed = true
            }
            queue.async { self?.onSegmentTranslated?(segment) }
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
        if finalizeAfterPause > 0, !volatileTail.isEmpty || segmenter.hasPending {
            soundLock.lock(); let quiet = quietSince; soundLock.unlock()
            if let quiet, now.timeIntervalSince(quiet) >= finalizeAfterPause, finalizedPause != quiet {
                finalizedPause = quiet
                onRawTranscript?("<finalize at pause>", false)
                engine.finalizeAtPause()
            }
        }
        let textStalled = segmenter.shouldFlushForSilence(now: now)
        if textStalled, silenceConfirmed(now: now) {
            rotate(reason: "silence")
        } else if textStalled, engineKind == .legacy, let chunk = segmenter.flush() {
            // SFSpeechRecognizer stalls like this mostly at sentence ends: cut there, but keep
            // the task — the speaker has not stopped, and rotating would lose their words.
            onRawTranscript?("<cut: stall>", false)
            emit(chunk)
            onPartial?(livePartial)
        } else if pausedBeforeStall(now: now), let chunk = segmenter.flush() {
            onRawTranscript?("<cut: pause>", false)
            emit(chunk)
            onPartial?(livePartial)
        } else if let chunk = segmenter.cutByTime(now: now) {
            onRawTranscript?("<cut: time>", false)
            emit(chunk)
            onPartial?(livePartial)
        } else if engine.needsPeriodicRestart, now.timeIntervalSince(segmenter.runStartedAt) > maxTaskDuration - rotationWindow,
                  audioQuiet(now: now) || now.timeIntervalSince(segmenter.runStartedAt) > maxTaskDuration {
            rotate(reason: "max duration")
        }
    }
}
