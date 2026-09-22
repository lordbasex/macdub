import Foundation
import AVFAudio

/// User preferences, persisted in `UserDefaults` on every change.
@MainActor
final class Settings: ObservableObject {
    private let defaults: UserDefaults

    @Published var sourceLocaleID: String { didSet { defaults.set(sourceLocaleID, forKey: "sourceLocaleID") } }
    @Published var targetLanguageID: String { didSet { defaults.set(targetLanguageID, forKey: "targetLanguageID") } }
    @Published var voiceIdentifier: String { didSet { defaults.set(voiceIdentifier, forKey: "voiceIdentifier") } }
    @Published var speechRate: Double { didSet { defaults.set(speechRate, forKey: "speechRate") } }
    @Published var volume: Double { didSet { defaults.set(volume, forKey: "volume") } }
    @Published var maxBacklog: Int { didSet { defaults.set(maxBacklog, forKey: "maxBacklog") } }
    @Published var speakTranslation: Bool { didSet { defaults.set(speakTranslation, forKey: "speakTranslation") } }
    @Published var showSubtitles: Bool { didSet { defaults.set(showSubtitles, forKey: "showSubtitles") } }
    @Published var showOriginalInSubtitles: Bool { didSet { defaults.set(showOriginalInSubtitles, forKey: "showOriginalInSubtitles") } }
    @Published var lastTargetBundleID: String { didSet { defaults.set(lastTargetBundleID, forKey: "lastTargetBundleID") } }
    @Published var silenceFlushInterval: Double { didSet { defaults.set(silenceFlushInterval, forKey: "silenceFlushInterval") } }
    /// Extra speech rate per queued sentence when the voice is behind (0 = never speed up).
    @Published var catchUpBoost: Double { didSet { defaults.set(catchUpBoost, forKey: "catchUpBoost") } }
    /// When the voice is behind, sentences recognized more than this many seconds ago are not spoken.
    @Published var maxSpokenLag: Double { didSet { defaults.set(maxSpokenLag, forKey: "maxSpokenLag") } }
    /// "tap" (Core Audio process tap: original can be lowered) or "sck" (ScreenCaptureKit).
    @Published var captureEngine: String { didSet { defaults.set(captureEngine, forKey: "captureEngine") } }
    /// Level (0…1) of the original audio under the dub. Only with the "tap" engine.
    @Published var originalVolume: Double { didSet { defaults.set(originalVolume, forKey: "originalVolume") } }
    /// Keep the original at full volume and only lower it while the translated voice speaks.
    @Published var duckOnlyWhileSpeaking: Bool { didSet { defaults.set(duckOnlyWhileSpeaking, forKey: "duckOnlyWhileSpeaking") } }
    @Published var autoScrollSubtitles: Bool { didSet { defaults.set(autoScrollSubtitles, forKey: "autoScrollSubtitles") } }
    /// Translated lines kept visible in the floating pill.
    @Published var pillLines: Int { didSet { defaults.set(pillLines, forKey: "pillLines") } }
    @Published var pillWidth: Double { didSet { defaults.set(pillWidth, forKey: "pillWidth") } }
    @Published var pillFontSize: Double { didSet { defaults.set(pillFontSize, forKey: "pillFontSize") } }
    /// Karaoke-style highlight of the words being spoken.
    @Published var highlightSpokenWords: Bool { didSet { defaults.set(highlightSpokenWords, forKey: "highlightSpokenWords") } }
    /// "system" or a language code; applied through AppleLanguages on next launch.
    @Published var interfaceLanguage: String { didSet { defaults.set(interfaceLanguage, forKey: "interfaceLanguage") } }
    /// "auto" (SpeechAnalyzer when macOS 26+ offers it, else SFSpeechRecognizer), "legacy" or "analyzer".
    @Published var recognitionEngine: String { didSet { defaults.set(recognitionEngine, forKey: "recognitionEngine") } }
    /// Seconds of silence from the captured app before MacDub reacts (0 = never).
    @Published var silenceTimeout: Double { didSet { defaults.set(silenceTimeout, forKey: "silenceTimeout") } }
    /// Stop dubbing when the silence timeout elapses (otherwise just show a notice).
    @Published var stopOnSilence: Bool { didSet { defaults.set(stopOnSilence, forKey: "stopOnSilence") } }
    @Published var globalHotKeys: Bool { didSet { defaults.set(globalHotKeys, forKey: "globalHotKeys") } }
    /// Persist each session's transcript to disk when dubbing stops.
    @Published var saveSessions: Bool { didSet { defaults.set(saveSessions, forKey: "saveSessions") } }
    /// Record the captured (original) audio of each session to ~/.macdub/audio for playback/export.
    @Published var recordAudio: Bool { didSet { defaults.set(recordAudio, forKey: "recordAudio") } }
    /// History playback: "original" (recorded audio only), "documentary" (original lowered under the
    /// translated voice) or "voice" (translated voice only). Remembered across sessions.
    @Published var historyAudioMode: String { didSet { defaults.set(historyAudioMode, forKey: "historyAudioMode") } }
    /// History playback subtitles: "original", "translation" or "both".
    @Published var historySubtitleMode: String { didSet { defaults.set(historySubtitleMode, forKey: "historySubtitleMode") } }
    /// Level (0…1) of the original audio under the voice in documentary mode.
    @Published var historyOriginalVolume: Double { didSet { defaults.set(historyOriginalVolume, forKey: "historyOriginalVolume") } }
    /// Seconds of captured audio kept in memory for MCP `get_audio_snippet` (0 = keep none).
    @Published var audioBufferSeconds: Double { didSet { defaults.set(audioBufferSeconds, forKey: "audioBufferSeconds") } }
    /// Also serve the MCP server over HTTP (Streamable HTTP transport) on `mcpHTTPPort`.
    @Published var mcpHTTPEnabled: Bool { didSet { defaults.set(mcpHTTPEnabled, forKey: "mcpHTTPEnabled") } }
    @Published var mcpHTTPPort: Int { didSet { defaults.set(mcpHTTPPort, forKey: "mcpHTTPPort") } }
    /// Menu-bar-only mode: no Dock icon (the app lives in the menu bar).
    @Published var hideDockIcon: Bool { didSet { defaults.set(hideDockIcon, forKey: "hideDockIcon") } }
    /// Start dubbing by itself as soon as the selected app starts playing audio.
    @Published var autoStartWhenAudio: Bool { didSet { defaults.set(autoStartWhenAudio, forKey: "autoStartWhenAudio") } }

    var usesProcessTap: Bool { captureEngine == "tap" }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        sourceLocaleID = defaults.string(forKey: "sourceLocaleID") ?? "en-US"
        targetLanguageID = defaults.string(forKey: "targetLanguageID") ?? "es"
        voiceIdentifier = defaults.string(forKey: "voiceIdentifier") ?? ""
        // Slightly above Apple's default: dubbing has to keep pace with the original speaker.
        speechRate = defaults.object(forKey: "speechRate") as? Double ?? 0.55
        volume = defaults.object(forKey: "volume") as? Double ?? 1
        maxBacklog = defaults.object(forKey: "maxBacklog") as? Int ?? 5
        speakTranslation = defaults.object(forKey: "speakTranslation") as? Bool ?? true
        showSubtitles = defaults.object(forKey: "showSubtitles") as? Bool ?? true
        showOriginalInSubtitles = defaults.object(forKey: "showOriginalInSubtitles") as? Bool ?? true
        lastTargetBundleID = defaults.string(forKey: "lastTargetBundleID") ?? "com.apple.Safari"
        silenceFlushInterval = defaults.object(forKey: "silenceFlushInterval") as? Double ?? 0.9
        maxSpokenLag = defaults.object(forKey: "maxSpokenLag") as? Double ?? 6
        catchUpBoost = defaults.object(forKey: "catchUpBoost") as? Double ?? 0.10
        captureEngine = defaults.string(forKey: "captureEngine") ?? "tap"
        originalVolume = defaults.object(forKey: "originalVolume") as? Double ?? 0.25
        duckOnlyWhileSpeaking = defaults.object(forKey: "duckOnlyWhileSpeaking") as? Bool ?? false
        autoScrollSubtitles = defaults.object(forKey: "autoScrollSubtitles") as? Bool ?? true
        pillLines = defaults.object(forKey: "pillLines") as? Int ?? 3
        pillWidth = defaults.object(forKey: "pillWidth") as? Double ?? 820
        pillFontSize = defaults.object(forKey: "pillFontSize") as? Double ?? 20
        highlightSpokenWords = defaults.object(forKey: "highlightSpokenWords") as? Bool ?? true
        interfaceLanguage = defaults.string(forKey: "interfaceLanguage") ?? "system"
        recognitionEngine = defaults.string(forKey: "recognitionEngine") ?? "auto"
        silenceTimeout = defaults.object(forKey: "silenceTimeout") as? Double ?? 30
        stopOnSilence = defaults.object(forKey: "stopOnSilence") as? Bool ?? false
        globalHotKeys = defaults.object(forKey: "globalHotKeys") as? Bool ?? true
        saveSessions = defaults.object(forKey: "saveSessions") as? Bool ?? true
        recordAudio = defaults.object(forKey: "recordAudio") as? Bool ?? true
        historyAudioMode = defaults.string(forKey: "historyAudioMode") ?? "original"
        historySubtitleMode = defaults.string(forKey: "historySubtitleMode") ?? "both"
        historyOriginalVolume = defaults.object(forKey: "historyOriginalVolume") as? Double ?? 0.2
        audioBufferSeconds = defaults.object(forKey: "audioBufferSeconds") as? Double ?? 60
        mcpHTTPEnabled = defaults.object(forKey: "mcpHTTPEnabled") as? Bool ?? false
        mcpHTTPPort = defaults.object(forKey: "mcpHTTPPort") as? Int ?? 8765
        hideDockIcon = defaults.object(forKey: "hideDockIcon") as? Bool ?? false
        autoStartWhenAudio = defaults.object(forKey: "autoStartWhenAudio") as? Bool ?? false
    }

    var sourceLocale: Locale { Locale(identifier: sourceLocaleID) }
    var targetLanguage: Locale.Language { Locale.Language(identifier: targetLanguageID) }

    /// Base language code of the target ("es" for "es-MX"), used to filter voices.
    var targetLanguageCode: String {
        targetLanguage.languageCode?.identifier ?? String(targetLanguageID.prefix(2))
    }
}
