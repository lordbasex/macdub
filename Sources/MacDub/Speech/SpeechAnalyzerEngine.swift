import Foundation
import Speech
import AVFAudio
import MacDubCore

// The SpeechAnalyzer API only exists in the macOS 26 SDK, which ships with Swift 6.2 toolchains.
// Older Command Line Tools compile the app without this engine (SFSpeechRecognizer is used).
#if compiler(>=6.2)

/// macOS 26 recognition through `SpeechAnalyzer` + `SpeechTranscriber`.
///
/// EXPERIMENTAL: compiled against the macOS 26 SDK but not yet exercised on a macOS 26 machine
/// (the project is developed on macOS 15). It is opt-in through Settings › Advanced.
///
/// Differences from `SFSpeechEngine` that matter to the manager:
/// - results are per utterance: *volatile* results replace each other until a *final* one lands,
///   which we append to `finalized`. The transcript we report is `finalized + volatile`;
/// - the analyzer never needs restarting. `restart()` just resets `finalized` so the cumulative
///   text stays short; a volatile utterance in flight is trimmed by the prefix already reported.
@available(macOS 26.0, *)
final class SpeechAnalyzerEngine: RecognitionEngine {
    var onTranscript: ((String, Bool) -> Void)?
    var onRunEnded: ((Error?) -> Void)?
    let needsPeriodicRestart = false

    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var converter: AVAudioConverter?
    private var analyzerFormat: AVAudioFormat?
    /// False until `bestAvailableAudioFormat` answered. Audio arriving before that is held in
    /// `pending`: yielding it unconverted made the analyzer trap on the unexpected format
    /// (`SpeechRecognizerWorker.preRunRecognition`, EXC_BREAKPOINT) as soon as it started.
    private var formatResolved = false
    private var pending: [AVAudioPCMBuffer] = []
    private var pendingFrames: AVAudioFramePosition = 0

    private let lock = NSLock()
    private var finalized = ""
    private var volatile = ""
    /// Text of the in-flight volatile utterance already reported before one or more `restart()`s;
    /// cut out of that utterance's later results (see `ReportedText`).
    private var reported = ""
    private let maxFinalizedCharacters = 3000

    /// Every result exactly as SpeechAnalyzer reports it, with its audio range (benchmark only).
    nonisolated(unsafe) static var rawResultHook: ((_ text: String, _ isFinal: Bool, _ range: String) -> Void)?

    static func isLocaleInstalled(_ locale: Locale) async -> Bool {
        let installed = await SpeechTranscriber.installedLocales
        return installed.contains { $0.identifier(.bcp47) == locale.identifier(.bcp47) }
    }

    /// Live translation: `.fastResults`. Without it SpeechAnalyzer may process a conversation
    /// (a sentence, then silence) in blocks of ~12 s of audio, so each sentence waited that long.
    var fastResults = false

    func start(locale: Locale) throws {
        let transcriber = SpeechTranscriber(locale: locale,
                                            transcriptionOptions: [],
                                            reportingOptions: fastResults ? [.volatileResults, .fastResults] : [.volatileResults],
                                            attributeOptions: [])
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.transcriber = transcriber
        self.analyzer = analyzer

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        input = continuation

        // Model download + start happen asynchronously; failures surface through onRunEnded.
        resultsTask = Task { [weak self] in
            do {
                if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                    Log.speech.info("SpeechAnalyzer: downloading assets for \(locale.identifier, privacy: .public)")
                    try await request.downloadAndInstall()
                }
                let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
                self?.setAnalyzerFormat(format)
                try await analyzer.start(inputSequence: stream)
                Log.speech.info("SpeechAnalyzer started (\(format?.description ?? "default format", privacy: .public))")

                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    Self.rawResultHook?(text, result.isFinal,
                                        "\(result.range.start.seconds)+\(result.range.duration.seconds)")
                    self?.handle(text: text, isFinal: result.isFinal)
                }
                self?.onRunEnded?(nil)
            } catch {
                Log.speech.error("SpeechAnalyzer failed: \(error.localizedDescription, privacy: .public)")
                self?.onRunEnded?(error)
            }
        }
    }

    private func setAnalyzerFormat(_ format: AVAudioFormat?) {
        lock.lock()
        analyzerFormat = format
        formatResolved = true
        let held = pending
        pending.removeAll()
        pendingFrames = 0
        lock.unlock()
        for buffer in held { append(buffer) }
    }

    /// Segment (and so translate and speak) finalized results only. SpeechAnalyzer's volatile
    /// results arrive fast but are rough — "the speecheech analyzer", words cut mid-way — and
    /// its final result for the same audio is a whole, corrected, punctuated sentence ("the
    /// speech analyzer object with our speech transcriber module."). Volatile text is then only
    /// shown live (`onVolatile`). Off: the older behaviour, lower latency, rougher text.
    var segmentsFinalsOnly = true
    var onVolatile: ((String) -> Void)?
    /// SpeechAnalyzer sometimes holds a final back until a very long sentence ends, taking the
    /// short sentences before it along (up to 20 s late in the benchmark). After this long
    /// without a final, sentences the volatile text has already completed go out anyway; the
    /// final is later trimmed of them (`reported`).
    var volatileFallbackAfter: TimeInterval = 5
    /// Upper bound on waiting: past it, the volatile text goes out up to its last clause mark
    /// (or all but its last words). Finals normally arrive every ~4 s; this acts when
    /// SpeechAnalyzer merged sentences or sat on one. Measured over 28 min: worst latency 19.6 →
    /// 12.4 s, longest silence 31.7 → 15.2 s, for 92 → 85 % of sentences spoken whole (7 s:
    /// 72 %). Cutting at audio pauses instead was tried and measured no better.
    var volatileHardCap: TimeInterval = 10
    /// When the volatile text now in flight started (first volatile result after a final or a
    /// promotion); the fallback clock, so a pause in speech never counts as waiting.
    private var volatileSince: Date?

    private func handle(text: String, isFinal: Bool) {
        if segmentsFinalsOnly {
            handleFinalsOnly(text: text, isFinal: isFinal)
            return
        }
        lock.lock()
        let trimmed = reported.isEmpty ? text : ReportedText.remainder(of: text, after: reported)
        var cumulative: String
        var reportFinal = false
        if isFinal {
            finalized += (finalized.isEmpty || trimmed.isEmpty ? "" : " ") + trimmed
            volatile = ""
            reported = ""
            cumulative = finalized
            if finalized.count > maxFinalizedCharacters {
                // Ask the manager to flush and rotate; nothing volatile is in flight right now.
                reportFinal = true
            }
        } else {
            volatile = trimmed
            cumulative = finalized + (finalized.isEmpty || volatile.isEmpty ? "" : " ") + volatile
        }
        lock.unlock()
        onTranscript?(cumulative, reportFinal)
    }

    private func handleFinalsOnly(text: String, isFinal: Bool) {
        lock.lock()
        // Results start with a space (" We're now…"); joining adds one, so drop it.
        let trimmed = (reported.isEmpty ? text : ReportedText.remainder(of: text, after: reported))
            .trimmingCharacters(in: .whitespaces)
        guard isFinal else {
            let now = Date()
            if volatileSince == nil { volatileSince = now }
            let waited = now.timeIntervalSince(volatileSince ?? now)
            // Past 5 s: sentences the volatile text completed. Past the cap: up to its last clause.
            let capped = volatileHardCap > 0 && waited > volatileHardCap
            let end = capped
                ? ReportedText.endOfCompletedClauses(in: trimmed) ?? ReportedText.endKeepingLastWords(in: trimmed)
                : waited > volatileFallbackAfter ? ReportedText.endOfCompletedSentences(in: trimmed) : nil
            let head = end.map { trimmed[..<$0].trimmingCharacters(in: .whitespaces) } ?? ""
            let promoted = !head.isEmpty
            if promoted {
                reported += (reported.isEmpty ? "" : " ") + head
                finalized += (finalized.isEmpty ? "" : " ") + head
                volatileSince = now
            }
            volatile = promoted ? ReportedText.remainder(of: trimmed, after: head) : trimmed
            let shown = volatile, cumulative = finalized
            // A capped piece ends at a comma, which the segmenter would keep pending: have the
            // manager flush it now (rotation keeps `reported`, see restart).
            let rotate = (promoted && capped) || finalized.count > maxFinalizedCharacters
            lock.unlock()
            onVolatile?(shown)
            if promoted { onTranscript?(cumulative, rotate) }
            return
        }
        finalized += (finalized.isEmpty || trimmed.isEmpty ? "" : " ") + trimmed
        volatile = ""
        reported = ""
        volatileSince = nil
        let cumulative = finalized
        let rotate = finalized.count > maxFinalizedCharacters
        lock.unlock()
        onVolatile?("")
        onTranscript?(cumulative, rotate)
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        guard formatResolved else {
            // Keep up to ~10 s while the model assets are checked; older audio is dropped.
            pending.append(buffer)
            pendingFrames += AVAudioFramePosition(buffer.frameLength)
            while pendingFrames > AVAudioFramePosition(buffer.format.sampleRate * 10), let first = pending.first {
                pendingFrames -= AVAudioFramePosition(first.frameLength)
                pending.removeFirst()
            }
            lock.unlock()
            return
        }
        let format = analyzerFormat
        lock.unlock()
        guard let input else { return }
        guard let format, format != buffer.format else {
            input.yield(AnalyzerInput(buffer: buffer))
            return
        }
        // Convert to the analyzer's preferred format (typically 16 kHz mono).
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: format)
        }
        guard let converter else { return }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        if error == nil, out.frameLength > 0 {
            input.yield(AnalyzerInput(buffer: out))
        }
    }

    func finalizeAtPause() {
        guard let analyzer else { return }
        Task { try? await analyzer.finalize(through: nil) }
    }

    var tailIsVolatile: Bool {
        lock.lock(); defer { lock.unlock() }
        // In finals-only mode the manager never sees volatile text.
        return !segmentsFinalsOnly && !volatile.isEmpty
    }

    func restart() { restart(holdingBackLastWord: false) }

    func restart(holdingBackLastWord: Bool) {
        lock.lock()
        finalized = ""
        if segmentsFinalsOnly {
            // Volatile text was never emitted; its final result will arrive whole.
            lock.unlock()
            return
        }
        // The utterance's next results repeat everything reported so far, across restarts.
        // A held-back last word was not emitted, so it stays out of `reported` and comes back.
        var emitted = volatile
        if holdingBackLastWord {
            let trimmed = emitted.trimmingCharacters(in: .whitespaces)
            emitted = trimmed.lastIndex(where: \.isWhitespace).map { String(trimmed[..<$0]) } ?? ""
        }
        if !emitted.isEmpty { reported += (reported.isEmpty ? "" : " ") + emitted }
        volatile = ""
        lock.unlock()
    }

    func stop() {
        input?.finish()
        input = nil
        resultsTask?.cancel()
        resultsTask = nil
        let analyzer = self.analyzer
        Task { await analyzer?.cancelAndFinishNow() }
        self.analyzer = nil
        transcriber = nil
        lock.lock()
        finalized = ""; volatile = ""; reported = ""; volatileSince = nil
        pending.removeAll(); pendingFrames = 0
        lock.unlock()
    }
}

#endif
