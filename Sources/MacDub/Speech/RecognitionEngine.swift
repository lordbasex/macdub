import Foundation
import Speech
import AVFAudio

/// A streaming speech recognizer as `SpeechAndTranslationManager` sees it. Implementations:
/// `SFSpeechEngine` (macOS 15, `SFSpeechRecognizer`) and `SpeechAnalyzerEngine` (macOS 26).
///
/// A *run* is one cumulative transcript that keeps being revised. The manager may end a run
/// (`restart()`) after silence or when it grows too long; the engine may end one itself by
/// reporting `isFinal` or `onRunEnded`. Callbacks arrive on arbitrary threads.
protocol RecognitionEngine: AnyObject {
    /// Latest cumulative transcript of the current run.
    var onTranscript: ((_ text: String, _ isFinal: Bool) -> Void)? { get set }
    /// The run ended on its own (error, or the recognizer closed the task).
    var onRunEnded: ((Error?) -> Void)? { get set }
    /// Whether the manager should rotate runs periodically (`SFSpeechRecognizer` tasks degrade).
    var needsPeriodicRestart: Bool { get }

    func start(locale: Locale) throws
    func append(_ buffer: AVAudioPCMBuffer)
    /// Begin a new run; the manager has already flushed the previous one.
    func restart()
    func stop()

    /// Provisional text not yet part of `onTranscript` (engines that segment finals only), for
    /// showing live; "" when it was finalized.
    var onVolatile: ((String) -> Void)? { get set }

    /// True when the end of the current transcript is still provisional (it may grow, e.g.
    /// "predomin" → "predominates"). Engines that report finished words only return false.
    var tailIsVolatile: Bool { get }
    /// `restart()`, except that the last word of the volatile tail was *not* emitted by the
    /// manager: it must come back at the start of the next results.
    func restart(holdingBackLastWord: Bool)
}

extension RecognitionEngine {
    var tailIsVolatile: Bool { false }
    func restart(holdingBackLastWord: Bool) { restart() }
}

enum RecognitionEngineKind: String, CaseIterable, Identifiable {
    case auto      // analyzer when the OS offers it, else legacy
    case legacy    // SFSpeechRecognizer, macOS 15+
    case analyzer  // SpeechAnalyzer / SpeechTranscriber, macOS 26+

    var id: String { rawValue }

    /// True only when the OS has SpeechAnalyzer *and* the app was built with an SDK that knows it.
    static var analyzerSupported: Bool {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) { return true }
        #endif
        return false
    }

    /// Why SpeechAnalyzer can't be used here, or nil when it can.
    static var analyzerUnavailableReason: String? {
        if analyzerSupported { return nil }
        if !SystemInfo.builtWithMacOS26SDK { return L("this build was compiled without the macOS 26 SDK") }
        return L("requires macOS 26")
    }

    /// Choices shown in the UI: on macOS 15 only "auto" and "legacy" make sense.
    static var available: [RecognitionEngineKind] {
        analyzerSupported ? [.auto, .analyzer, .legacy] : [.auto, .legacy]
    }

    /// The concrete engine `auto` resolves to on this machine.
    var resolved: RecognitionEngineKind {
        switch self {
        case .auto: return Self.analyzerSupported ? .analyzer : .legacy
        case .analyzer: return Self.analyzerSupported ? .analyzer : .legacy
        case .legacy: return .legacy
        }
    }

    var title: String {
        switch self {
        case .auto: return Self.analyzerSupported
            ? L("Automatic · SpeechAnalyzer (macOS 26)")
            : L("Automatic · SFSpeechRecognizer (SpeechAnalyzer needs macOS 26)")
        case .legacy: return "SFSpeechRecognizer"
        case .analyzer: return "SpeechAnalyzer · macOS 26 (experimental)"
        }
    }
}

// MARK: - SFSpeechRecognizer engine

/// Wraps `SFSpeechRecognizer` on-device recognition. Each run is one `SFSpeechAudioBufferRecognitionRequest`.
final class SFSpeechEngine: RecognitionEngine {
    var onTranscript: ((String, Bool) -> Void)?
    var onRunEnded: ((Error?) -> Void)?
    var onVolatile: ((String) -> Void)?  // SFSpeechRecognizer's partials go through onTranscript
    let needsPeriodicRestart = true

    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var generation = 0
    private let lock = NSLock()

    /// Whether this Mac can recognise that language without the network.
    ///
    /// The answer is **memoised**, and that is the whole point: asking means building an
    /// `SFSpeechRecognizer` and reading `supportsOnDeviceRecognition`, which is a *synchronous
    /// XPC round-trip* to the speech daemon. The picker of spoken languages asked it once per
    /// language inside a SwiftUI body, so every redraw fired one blocking call per language —
    /// and while dubbing runs the body redraws many times a second (level meter, partials).
    /// macOS filed CPU-exhaustion reports at 78 % average and the window froze.
    ///
    /// The cache can go stale in exactly one way: the person downloads a dictation language
    /// while the app is open. `invalidateOnDeviceCache()` covers it and is called wherever the
    /// app re-reads its capabilities.
    static func supportsOnDevice(_ locale: Locale) -> Bool {
        let key = locale.identifier
        onDeviceLock.lock()
        if let known = onDeviceCache[key] {
            onDeviceLock.unlock()
            return known
        }
        onDeviceLock.unlock()

        let answer = SFSpeechRecognizer(locale: locale)?.supportsOnDeviceRecognition == true

        onDeviceLock.lock()
        onDeviceCache[key] = answer
        onDeviceLock.unlock()
        return answer
    }

    /// Forget what was asked, so a language downloaded just now is seen.
    static func invalidateOnDeviceCache() {
        onDeviceLock.lock()
        onDeviceCache.removeAll()
        onDeviceLock.unlock()
    }

    private static var onDeviceCache: [String: Bool] = [:]
    private static let onDeviceLock = NSLock()

    func start(locale: Locale) throws {
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            throw MacDubError.speechLocaleUnsupported(locale.identifier)
        }
        guard recognizer.supportsOnDeviceRecognition else {
            throw MacDubError.onDeviceRecognitionUnavailable(locale.identifier)
        }
        guard recognizer.isAvailable else {
            throw MacDubError.speechRecognizerUnavailable(locale.identifier)
        }
        recognizer.defaultTaskHint = .dictation
        recognizer.queue = OperationQueue()
        self.recognizer = recognizer
        restart()
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); let request = self.request; lock.unlock()
        request?.append(buffer)
    }

    func restart() {
        lock.lock()
        task?.cancel()
        generation += 1
        let gen = generation
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        request.taskHint = .dictation
        request.addsPunctuation = true
        self.request = request
        guard let recognizer else { lock.unlock(); return }
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            self.lock.lock(); let current = self.generation == gen; self.lock.unlock()
            guard current else { return } // stale run
            if let result {
                self.onTranscript?(result.bestTranscription.formattedString, result.isFinal)
            } else if let error {
                self.onRunEnded?(error)
            }
        }
        lock.unlock()
    }

    func stop() {
        lock.lock()
        generation += 1
        task?.cancel()
        task = nil
        request?.endAudio()
        request = nil
        recognizer = nil
        lock.unlock()
    }
}
