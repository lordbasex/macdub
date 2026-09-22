import Foundation
import Speech
import AVFAudio

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

    private let lock = NSLock()
    private var finalized = ""
    private var volatile = ""
    /// Characters of the in-flight volatile utterance already reported before a `restart()`.
    private var volatileTrim = 0
    private let maxFinalizedCharacters = 3000

    static func isLocaleInstalled(_ locale: Locale) async -> Bool {
        let installed = await SpeechTranscriber.installedLocales
        return installed.contains { $0.identifier(.bcp47) == locale.identifier(.bcp47) }
    }

    func start(locale: Locale) throws {
        let transcriber = SpeechTranscriber(locale: locale,
                                            transcriptionOptions: [],
                                            reportingOptions: [.volatileResults],
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
                    self?.handle(text: String(result.text.characters), isFinal: result.isFinal)
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
        lock.unlock()
    }

    private func handle(text: String, isFinal: Bool) {
        lock.lock()
        let trimmed = volatileTrim > 0 ? String(text.dropFirst(min(volatileTrim, text.count))) : text
        var cumulative: String
        var reportFinal = false
        if isFinal {
            finalized += (finalized.isEmpty || trimmed.isEmpty ? "" : " ") + trimmed
            volatile = ""
            volatileTrim = 0
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

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
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

    func restart() {
        lock.lock()
        finalized = ""
        volatileTrim = volatile.count
        volatile = ""
        lock.unlock()
    }

    func stop() {
        input?.finish()
        input = nil
        resultsTask?.cancel()
        resultsTask = nil
        let analyzer = self.analyzer
        Task { try? await analyzer?.cancelAndFinishNow() }
        self.analyzer = nil
        transcriber = nil
        lock.lock()
        finalized = ""; volatile = ""; volatileTrim = 0
        lock.unlock()
    }
}

#endif
