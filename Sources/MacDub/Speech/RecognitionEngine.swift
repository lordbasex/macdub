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
    let needsPeriodicRestart = true

    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var generation = 0
    private let lock = NSLock()

    static func supportsOnDevice(_ locale: Locale) -> Bool {
        SFSpeechRecognizer(locale: locale)?.supportsOnDeviceRecognition == true
    }

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
