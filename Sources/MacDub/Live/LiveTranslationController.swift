import Foundation
import AVFAudio
import Translation
import MacDubCore

/// Live translation: a conversation in two languages through a call app (Meet, Zoom…).
///
/// - **You → them**: the microphone → SpeechAnalyzer → translation → a voice (yours, with
///   Personal Voice) → a virtual audio device (BlackHole) the call app uses as its microphone.
/// - **Them → you**: the call app's audio (process tap, original lowered) → SpeechAnalyzer →
///   translation → another voice in your headphones.
///
/// Both recognizers run in this process: two SpeechAnalyzers do, at full quality (two
/// SFSpeechRecognizers would not), so this needs macOS 26. SpeechAnalyzer runs with
/// `.fastResults` and finalizes at a 0.5 s pause: a conversation is a sentence and then silence,
/// and without that it held each sentence back ~12 s (measured end to end: 1.8 s median).
@MainActor
final class LiveTranslationController: ObservableObject {
    enum Phase: String { case idle, starting, running, stopping }
    enum Side: String { case me, them }

    struct Line: Identifiable {
        let id = UUID()
        let side: Side
        let original: String
        var translated: String?
        let recognizedAt: Date
        var spokenAt: Date?
        var failed = false
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var lines: [Line] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var micLevel: Float = 0
    @Published private(set) var callLevel: Float = 0
    @Published private(set) var virtualMicAvailable = false
    @Published private(set) var speakersInUse = false
    let startedAt = Date()

    // Choices, kept between launches.
    @Published var myLocaleID: String { didSet { save("myLocaleID", myLocaleID); refreshVoices() } }
    @Published var theirLocaleID: String { didSet { save("theirLocaleID", theirLocaleID); refreshVoices() } }
    /// Voice lists, kept here: `speechVoices()` is slow, and a view body asking for it on every
    /// redraw stalls the window.
    @Published private(set) var voicesForThem: [AVSpeechSynthesisVoice] = []
    @Published private(set) var voicesForMe: [AVSpeechSynthesisVoice] = []
    /// Speaks *their* language into the call — your Personal Voice, ideally.
    @Published var voiceForThemID: String { didSet { save("voiceForThemID", voiceForThemID) } }
    /// Speaks *your* language in your headphones.
    @Published var voiceForMeID: String { didSet { save("voiceForMeID", voiceForMeID) } }
    @Published var originalVolume: Double { didSet { save("originalVolume", originalVolume); tap.passthroughGain = Float(originalVolume) } }
    @Published var virtualMicName: String { didSet { save("virtualMicName", virtualMicName); refreshDevices() } }

    static var isSupported: Bool {
        if #available(macOS 26.0, *), RecognitionEngineKind.analyzerSupported { return true }
        return false
    }

    private let defaults = UserDefaults.standard
    private let tap = ProcessTapCaptureManager()
    private var mic: LiveMicrophone?
    private var toThem: SpeechAndTranslationManager?
    private var fromThem: SpeechAndTranslationManager?
    private var speaker: LiveDeviceSpeaker?
    private let myVoice = VoiceSynthesisManager()
    private var sessions: [Side: AnyObject] = [:]   // TranslationSession (macOS 26)
    private var lastLevel = Date.distantPast

    init() {
        myLocaleID = defaults.string(forKey: "live.myLocaleID") ?? "es-MX"
        theirLocaleID = defaults.string(forKey: "live.theirLocaleID") ?? "en-US"
        voiceForThemID = defaults.string(forKey: "live.voiceForThemID") ?? ""
        voiceForMeID = defaults.string(forKey: "live.voiceForMeID") ?? ""
        originalVolume = defaults.object(forKey: "live.originalVolume") as? Double ?? 0.15
        virtualMicName = defaults.string(forKey: "live.virtualMicName") ?? "BlackHole 2ch"
        refreshDevices()
        refreshVoices()
    }

    /// Re-reads the voices for both languages and fills in a choice that is missing: your
    /// Personal Voice for them when there is one, a regular voice for you.
    func refreshVoices() {
        voicesForThem = Self.voices(for: theirLocaleID)
        voicesForMe = Self.voices(for: myLocaleID)
        if !voicesForThem.contains(where: { $0.identifier == voiceForThemID }) {
            voiceForThemID = voicesForThem.first?.identifier ?? ""
        }
        if !voicesForMe.contains(where: { $0.identifier == voiceForMeID }) {
            voiceForMeID = (voicesForMe.first { !VoiceSynthesisManager.isPersonal($0) } ?? voicesForMe.first)?.identifier ?? ""
        }
    }

    private func save(_ key: String, _ value: Any) { defaults.set(value, forKey: "live." + key) }

    func refreshDevices() {
        virtualMicAvailable = LiveAudio.outputDevice(named: virtualMicName) != nil
        speakersInUse = LiveAudio.defaultOutputIsBuiltInSpeaker()
    }

    /// Voices for one language, the Personal Voice first (it may speak several languages).
    static func voices(for localeID: String) -> [AVSpeechSynthesisVoice] {
        let code = String(localeID.prefix(2))
        let personal = AVSpeechSynthesisVoice.speechVoices().filter(VoiceSynthesisManager.isPersonal)
        let regular = VoiceSynthesisManager.voices(forLanguageCode: code).filter { !VoiceSynthesisManager.isPersonal($0) }
        return personal + regular
    }

    func clear() { lines.removeAll() }

    // MARK: Start / stop

    func start(target: CaptureTarget) async {
        guard phase == .idle else { return }
        errorMessage = nil
        guard #available(macOS 26.0, *) else {
            errorMessage = L("Live translation needs macOS 26 or later.")
            return
        }
        phase = .starting
        refreshDevices()
        do {
            guard let device = LiveAudio.outputDevice(named: virtualMicName) else {
                throw LiveError(LF("No %@ audio device. Install it with: brew install --cask blackhole-2ch", virtualMicName))
            }
            guard await AVAudioApplication.requestRecordPermission() else {
                throw LiveError(L("MacDub may not use the microphone. Allow it in System Settings › Privacy & Security › Microphone."))
            }
            if SpeechAndTranslationManager.authorizationStatus() != .authorized,
               await SpeechAndTranslationManager.requestAuthorization() != .authorized {
                throw MacDubError.speechRecognitionDenied
            }
            let me = Locale(identifier: myLocaleID), them = Locale(identifier: theirLocaleID)
            try await prepareSessions(me: me, them: them)

            let speaker = try LiveDeviceSpeaker(device: device)
            self.speaker = speaker

            // You → them.
            let toThem = makeManager()
            toThem.onSegmentRecognized = { [weak self] segment in
                Task { @MainActor in self?.heard(segment.original, side: .me) }
            }
            try toThem.start(sourceLocale: me, engineKind: .analyzer)
            self.toThem = toThem
            let mic = LiveMicrophone { [weak self, toThem] buffer, peak in
                toThem.append(buffer)
                Task { @MainActor in self?.level(mic: peak) }
            }
            try mic.start()
            self.mic = mic

            // Them → you.
            let fromThem = makeManager()
            fromThem.onSegmentRecognized = { [weak self] segment in
                Task { @MainActor in self?.heard(segment.original, side: .them) }
            }
            try fromThem.start(sourceLocale: them, engineKind: .analyzer)
            self.fromThem = fromThem
            tap.onLevel = { [weak self] level in Task { @MainActor in self?.level(call: level) } }
            try tap.start(target: target) { [fromThem] buffer in fromThem.append(buffer) }
            tap.passthroughGain = Float(originalVolume)

            myVoice.onSegmentStarted = { [weak self] id in self?.spoke(id) }
            phase = .running
            Log.app.info("Live translation running: \(self.myLocaleID, privacy: .public) ↔ \(self.theirLocaleID, privacy: .public) via \(self.virtualMicName, privacy: .public)")
        } catch {
            errorMessage = error.localizedDescription
            await teardown()
        }
    }

    func stop() async {
        guard phase == .running || phase == .starting else { return }
        await teardown()
    }

    private func teardown() async {
        phase = .stopping
        mic?.stop(); mic = nil
        tap.stop()
        toThem?.stop(); toThem = nil
        fromThem?.stop(); fromThem = nil
        myVoice.stop()
        await speaker?.stop(); speaker = nil
        sessions.removeAll()
        micLevel = 0; callLevel = 0
        phase = .idle
    }

    private func makeManager() -> SpeechAndTranslationManager {
        let manager = SpeechAndTranslationManager(translator: TranslationBridge())
        manager.translatesSegments = false
        manager.analyzerFastResults = true
        manager.finalizeAfterPause = 0.5
        return manager
    }

    @available(macOS 26.0, *)
    private func prepareSessions(me: Locale, them: Locale) async throws {
        for (side, from, to) in [(Side.me, me, them), (Side.them, them, me)] {
            let status = await TranslationCatalog.status(from: from.language, to: to.language)
            guard status == .installed else {
                throw LiveError(LF("Download the %@ → %@ translation first (System Settings › General › Language & Region › Translation Languages).",
                                   from.identifier, to.identifier))
            }
            let session = TranslationSession(installedSource: from.language, target: to.language)
            _ = try? await session.translate("Hola")   // loads the model before anyone speaks
            sessions[side] = session
        }
    }

    // MARK: Pipeline events

    private func heard(_ text: String, side: Side) {
        guard phase == .running else { return }
        let line = Line(side: side, original: text, recognizedAt: Date())
        lines.append(line)
        if lines.count > 300 { lines.removeFirst(lines.count - 300) }
        guard #available(macOS 26.0, *), let session = sessions[side] as? TranslationSession else { return }
        let id = line.id
        Task {
            do {
                let translated = try await session.translate(text).targetText
                self.translated(id, translated)
            } catch {
                if let i = lines.firstIndex(where: { $0.id == id }) { lines[i].failed = true }
            }
        }
    }

    private func translated(_ id: UUID, _ text: String) {
        guard let i = lines.firstIndex(where: { $0.id == id }) else { return }
        lines[i].translated = text
        switch lines[i].side {
        case .me:
            // Into the call, in their language.
            let voice = AVSpeechSynthesisVoice(identifier: voiceForThemID)
                ?? Self.voices(for: theirLocaleID).first { !VoiceSynthesisManager.isPersonal($0) }
            Task { [speaker] in
                let buffers = await LiveAudio.render(text, voice: voice)
                await speaker?.enqueue(buffers) { Task { @MainActor [weak self] in self?.spoke(id) } }
            }
        case .them:
            // In your headphones, in your language.
            myVoice.voiceIdentifier = voiceForMeID.isEmpty ? nil : voiceForMeID
            myVoice.language = myLocaleID
            myVoice.speak(text, segmentID: id)
        }
    }

    private func spoke(_ id: UUID) {
        if let i = lines.firstIndex(where: { $0.id == id }) { lines[i].spokenAt = Date() }
    }

    private func level(mic peak: Float? = nil, call: Float? = nil) {
        if let peak { micLevel = max(peak, micLevel * 0.8) }
        if let call { callLevel = call }
    }

    private struct LiveError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}
