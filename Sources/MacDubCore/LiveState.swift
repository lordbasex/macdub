import Foundation

/// Snapshot of the running session that the app writes to disk and the MCP server reads.
///
/// Location: `~/Library/Application Support/MacDub/live.json`. The app rewrites it (atomically)
/// whenever the transcript or the phase changes, throttled to a few times per second.
public struct LiveState: Codable, Equatable {
    public struct SegmentDTO: Codable, Equatable {
        public var original: String
        public var translated: String?
        public var recognizedAt: Date
        public var spokenAt: Date?

        public init(_ segment: Segment) {
            original = segment.original
            translated = segment.translated
            recognizedAt = segment.recognizedAt
            spokenAt = segment.spokenAt
        }

        public var segment: Segment {
            var s = Segment(original: original, translated: translated, recognizedAt: recognizedAt)
            s.spokenAt = spokenAt
            return s
        }
    }

    public struct Target: Codable, Equatable {
        public var name: String
        public var bundleIdentifier: String
        public init(name: String, bundleIdentifier: String) {
            self.name = name
            self.bundleIdentifier = bundleIdentifier
        }
    }

    public var phase: String                 // idle | starting | running | stopping
    public var target: Target?
    public var availableTargets: [Target]
    public var sourceLocale: String
    public var targetLanguage: String
    public var sessionStart: Date
    public var partial: String
    public var segments: [SegmentDTO]
    public var updatedAt: Date
    public var appPID: Int32
    /// Mean seconds from sentence end to translation / to voice (last 10), 0 when unknown.
    public var translationLatency: Double = 0
    public var speechLatency: Double = 0
    /// "tap" or "sck" while running.
    public var captureEngine: String?
    /// "legacy" or "analyzer" while running.
    public var recognitionEngine: String?
    /// Seconds since the captured app last produced audio (nil when not running / unknown).
    public var silentFor: Double?

    public struct Voice: Codable, Equatable {
        public var identifier: String
        public var name: String
        public var language: String
        public var quality: String
        public init(identifier: String, name: String, language: String, quality: String) {
            self.identifier = identifier; self.name = name; self.language = language; self.quality = quality
        }
    }
    /// Current voice settings and the choices a client may pick from (see MacDubCommand set_*).
    public var voiceIdentifier: String?
    public var speakTranslation: Bool = true
    public var originalVolume: Double = 1
    public var duckOnlyWhileSpeaking: Bool = false
    public var availableVoices: [Voice] = []
    public var availableSourceLocales: [String] = []
    public var availableTargetLanguages: [String] = []

    public init(phase: String, target: Target?, availableTargets: [Target], sourceLocale: String,
                targetLanguage: String, sessionStart: Date, partial: String, segments: [SegmentDTO],
                updatedAt: Date = Date(), appPID: Int32 = ProcessInfo.processInfo.processIdentifier) {
        self.phase = phase
        self.target = target
        self.availableTargets = availableTargets
        self.sourceLocale = sourceLocale
        self.targetLanguage = targetLanguage
        self.sessionStart = sessionStart
        self.partial = partial
        self.segments = segments
        self.updatedAt = updatedAt
        self.appPID = appPID
    }
}

public enum LiveStateStore {
    public static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("MacDub", isDirectory: true)
    }

    public static var url: URL { directory.appendingPathComponent("live.json") }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public static func write(_ state: LiveState) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try encoder.encode(state).write(to: url, options: .atomic)
    }

    public static func read() throws -> LiveState {
        try decoder.decode(LiveState.self, from: Data(contentsOf: url))
    }

    /// True when the app that wrote the snapshot is still running.
    public static func isAppAlive(_ state: LiveState) -> Bool {
        kill(state.appPID, 0) == 0
    }
}

/// Commands another process (the MCP server) can send to the running app, over
/// `DistributedNotificationCenter`. The app observes `notificationName` and acts on `userInfo`.
public enum MacDubCommand {
    public static let notificationName = Notification.Name("com.lordbasex.MacDub.command")

    public enum Action: String {
        case start, stop, selectTarget, clearTranscript
        case setLanguages      // sourceLocale?, targetLanguage?  (only applied while idle)
        case setVoice          // voiceIdentifier
        case setSpeak          // enabled: "true"/"false"
        case setOriginalVolume // level: 0…1, duckOnlyWhileSpeaking?: "true"/"false"
        case exportAudio       // seconds, path → the app writes a 16 kHz mono WAV of the last N seconds
    }

    public static func post(_ action: Action, bundleIdentifier: String? = nil, values: [String: String] = [:]) {
        var info = values
        info["action"] = action.rawValue
        if let bundleIdentifier { info["bundleIdentifier"] = bundleIdentifier }
        DistributedNotificationCenter.default().postNotificationName(
            notificationName, object: nil, userInfo: info, deliverImmediately: true)
    }
}
