import Foundation
import AVFAudio
import Translation
import Speech
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
    /// How a line arrived: spoken, a chat message, or typed in MacDub.
    enum Via: String { case voice, chat, typed }

    struct Line: Identifiable {
        let id = UUID()
        let side: Side
        var via: Via = .voice
        /// Who wrote it, for chat messages.
        var author: String?
        let original: String
        var translated: String?
        let recognizedAt: Date
        /// When the speaker went quiet after it: the end of the sentence, for the total delay.
        var speechEndedAt: Date?
        var translatedAt: Date?
        var spokenAt: Date?

        /// End of the sentence → its text (recognition).
        var transcription: TimeInterval? { speechEndedAt.map { recognizedAt.timeIntervalSince($0) } }
        /// Text → translation.
        var translation: TimeInterval? { translatedAt.map { $0.timeIntervalSince(recognizedAt) } }
        /// Text → the translated voice starts (translating and making the voice).
        var audio: TimeInterval? { spokenAt.map { $0.timeIntervalSince(recognizedAt) } }
        /// End of the sentence → the translated voice starts.
        var total: TimeInterval? { spokenAt.map { $0.timeIntervalSince(speechEndedAt ?? recognizedAt) } }
        var failed = false
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var lines: [Line] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var micLevel: Float = 0
    @Published private(set) var callLevel: Float = 0
    /// What is being said right now on each side, not yet a sentence (the "typing…" bubble).
    @Published private(set) var partial: [Side: String] = [:]
    /// Sides someone is talking on right now.
    @Published private(set) var speaking: Set<Side> = []
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
    /// The microphone you speak into ("": the system's default input).
    @Published var micUID: String { didSet { save("micUID", micUID) } }
    @Published private(set) var microphones: [LiveAudio.InputDevice] = []

    /// A language live translation can hear: SpeechAnalyzer's, those on this Mac first.
    struct LanguageOption: Identifiable, Hashable {
        let id: String            // BCP-47, e.g. "es-MX"
        let name: String
        let installed: Bool       // speech model already on this Mac
        let personalVoice: Bool   // your Personal Voice speaks it (as macOS reports it)
    }
    @Published private(set) var languages: [LanguageOption] = []
    @Published private(set) var defaultMicName: String?
    /// What you say reaches them as audio (the virtual microphone)…
    @Published var sendAudio: Bool { didSet { save("sendAudio", sendAudio) } }
    /// …and/or as a message in the call's chat (the Meet extension).
    @Published var sendChat: Bool { didSet { save("sendChat", sendChat) } }
    /// Chat messages they write are translated into the conversation…
    @Published var translateChat: Bool { didSet { save("translateChat", translateChat) } }
    /// …and read aloud in your headphones.
    @Published var speakChat: Bool { didSet { save("speakChat", speakChat) } }
    /// The Meet extension asked for messages in the last few seconds.
    @Published private(set) var chatConnected = false
    private var outbox: [String] = []
    private var sentToChat: [String] = []   // our own messages come back through the chat: skip them
    private var lastChatPoll = Date.distantPast
    private var chatTimer: Timer?

    static var isSupported: Bool {
        if #available(macOS 26.0, *), RecognitionEngineKind.analyzerSupported { return true }
        return false
    }

    // History: a conversation is saved like a dubbing session (settings from AppState).
    var saveSessions = true
    var recordAudio = true
    var onArchive: ((SessionRecord) -> Void)?
    private var sessionID = UUID().uuidString
    private var sessionStartedAt = Date()
    private var targetName: String?
    private var targetBundle: String?
    private let micRecorder = SessionAudioRecorder()
    private let callRecorder = SessionAudioRecorder()

    private let defaults = UserDefaults.standard
    private let tap = ProcessTapCaptureManager()
    private var mic: LiveMicrophone?
    private var toThem: SpeechAndTranslationManager?
    private var fromThem: SpeechAndTranslationManager?
    private var speaker: LiveDeviceSpeaker?
    private let myVoice = VoiceSynthesisManager()
    private var sessions: [Side: AnyObject] = [:]   // TranslationSession (macOS 26)
    // Levels are published ~15 times a second: every audio buffer (~47/s per side) redrew the
    // whole conversation and kept the main thread busy.
    private var lastMicLevel = Date.distantPast, lastCallLevel = Date.distantPast
    /// Start of the current silence on each side (nil while someone speaks).
    private var quietSince: [Side: Date] = [:]
    private var loudAt: [Side: Date] = [:]

    init() {
        myLocaleID = defaults.string(forKey: "live.myLocaleID") ?? "es-MX"
        theirLocaleID = defaults.string(forKey: "live.theirLocaleID") ?? "en-US"
        voiceForThemID = defaults.string(forKey: "live.voiceForThemID") ?? ""
        voiceForMeID = defaults.string(forKey: "live.voiceForMeID") ?? ""
        originalVolume = defaults.object(forKey: "live.originalVolume") as? Double ?? 0.15
        virtualMicName = defaults.string(forKey: "live.virtualMicName") ?? "BlackHole 2ch"
        micUID = defaults.string(forKey: "live.micUID") ?? ""
        sendAudio = defaults.object(forKey: "live.sendAudio") as? Bool ?? true
        sendChat = defaults.object(forKey: "live.sendChat") as? Bool ?? false
        translateChat = defaults.object(forKey: "live.translateChat") as? Bool ?? true
        speakChat = defaults.object(forKey: "live.speakChat") as? Bool ?? false
        refreshDevices()
        refreshVoices()
        Task { await loadLanguages() }
    }

    /// SpeechAnalyzer's languages: a language SFSpeechRecognizer knows but SpeechAnalyzer does not
    /// would fail to start.
    func loadLanguages() async {
        guard #available(macOS 26.0, *) else { return }
        let supported = await SpeechTranscriber.supportedLocales
        let installed = Set(await SpeechTranscriber.installedLocales.map { $0.identifier(.bcp47) })
        let personal = Set(AVSpeechSynthesisVoice.speechVoices().filter(VoiceSynthesisManager.isPersonal).map { $0.language })
        var options = supported.map { locale -> LanguageOption in
            let id = locale.identifier(.bcp47)
            return LanguageOption(id: id, name: SpeechAndTranslationManager.displayName(Locale(identifier: id)),
                                  installed: installed.contains(id), personalVoice: personal.contains(id))
        }
        // Keep choices made before, even if SpeechAnalyzer names them differently.
        for id in [myLocaleID, theirLocaleID] where !options.contains(where: { $0.id == id }) {
            options.append(LanguageOption(id: id, name: SpeechAndTranslationManager.displayName(Locale(identifier: id)),
                                          installed: false, personalVoice: personal.contains(id)))
        }
        languages = options.sorted {
            if $0.installed != $1.installed { return $0.installed }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// Re-reads the voices for both languages and fills in a choice never made: your Personal
    /// Voice for them when there is one, a regular voice for you. A saved choice is never
    /// replaced — right after launch macOS may not list the Personal Voice yet.
    func refreshVoices() {
        voicesForThem = Self.voices(for: theirLocaleID)
        voicesForMe = Self.voices(for: myLocaleID)
        if voiceForThemID.isEmpty {
            voiceForThemID = voicesForThem.first?.identifier ?? ""
        }
        if voiceForMeID.isEmpty {
            voiceForMeID = (voicesForMe.first { !VoiceSynthesisManager.isPersonal($0) } ?? voicesForMe.first)?.identifier ?? ""
        }
    }

    private func save(_ key: String, _ value: Any) { defaults.set(value, forKey: "live." + key) }

    func refreshDevices() {
        virtualMicAvailable = LiveAudio.outputDevice(named: virtualMicName) != nil
        microphones = LiveAudio.inputDevices(excluding: virtualMicName)
        defaultMicName = LiveAudio.defaultInputName()
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
            let device = LiveAudio.outputDevice(named: virtualMicName)
            if sendAudio, device == nil {
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

            // A new conversation for History; both sides recorded against the same clock.
            sessionID = UUID().uuidString
            sessionStartedAt = Date()
            targetName = target.name
            targetBundle = target.bundleIdentifier
            if saveSessions && recordAudio {
                micRecorder.begin(url: partURL("me"), sessionStart: sessionStartedAt)
                callRecorder.begin(url: partURL("them"), sessionStart: sessionStartedAt)
            }

            if sendAudio, let device { speaker = try LiveDeviceSpeaker(device: device) }

            // You → them.
            let toThem = makeManager()
            toThem.onSegmentRecognized = { [weak self] segment in
                Task { @MainActor in self?.heard(segment.original, side: .me) }
            }
            toThem.onPartial = { [weak self] text in Task { @MainActor in self?.setPartial(text, side: .me) } }
            try toThem.start(sourceLocale: me, engineKind: .analyzer)
            self.toThem = toThem
            let mic = LiveMicrophone(deviceUID: micUID.isEmpty ? nil : micUID) { [weak self, toThem, micRecorder] buffer, peak in
                toThem.append(buffer)
                micRecorder.append(buffer)
                Task { @MainActor in self?.level(mic: peak) }
            }
            try mic.start()
            self.mic = mic

            // Them → you.
            let fromThem = makeManager()
            fromThem.onSegmentRecognized = { [weak self] segment in
                Task { @MainActor in self?.heard(segment.original, side: .them) }
            }
            fromThem.onPartial = { [weak self] text in Task { @MainActor in self?.setPartial(text, side: .them) } }
            try fromThem.start(sourceLocale: them, engineKind: .analyzer)
            self.fromThem = fromThem
            tap.onLevel = { [weak self] level in Task { @MainActor in self?.level(call: level) } }
            try tap.start(target: target) { [fromThem, callRecorder] buffer in
                fromThem.append(buffer)
                callRecorder.append(buffer)
            }
            tap.passthroughGain = Float(originalVolume)

            myVoice.onSegmentStarted = { [weak self] id in self?.spoke(id) }
            chatTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.checkChatConnection() }
            }
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
        let wasRunning = phase == .running
        phase = .stopping
        mic?.stop(); mic = nil
        tap.stop()
        toThem?.stop(); toThem = nil
        fromThem?.stop(); fromThem = nil
        myVoice.stop()
        await speaker?.stop(); speaker = nil
        sessions.removeAll()
        outbox.removeAll()
        if wasRunning { await archive() } else { micRecorder.discard(keepFinishedTake: false); callRecorder.discard(keepFinishedTake: false) }
        chatTimer?.invalidate(); chatTimer = nil
        chatConnected = false
        micLevel = 0; callLevel = 0
        partial.removeAll(); speaking.removeAll()
        phase = .idle
    }

    private func partURL(_ side: String) -> URL {
        MacDubPaths.audioDirectory.appendingPathComponent("\(sessionID)-\(side)").appendingPathExtension(MacDubPaths.audioExtension)
    }

    /// Saves the conversation: both takes mixed into one file, each line with who said it.
    private func archive() async {
        let (mic, call) = (micRecorder, callRecorder)
        let parts = await withCheckedContinuation { cont in
            mic.finish { me in call.finish { them in cont.resume(returning: [me, them].compactMap { $0 }) } }
        }
        let conversation = lines
        guard saveSessions, !conversation.isEmpty else {
            parts.forEach { try? FileManager.default.removeItem(at: $0) }
            return
        }
        var audioFile: String?
        if !parts.isEmpty {
            let mixed = SessionStore.audioURL(for: sessionID)
            do {
                try SessionAudioRecorder.mix(parts, into: mixed)
                audioFile = mixed.lastPathComponent
            } catch {
                Log.app.error("Live translation: could not mix the recording: \(error.localizedDescription, privacy: .public)")
            }
            parts.forEach { try? FileManager.default.removeItem(at: $0) }
        }
        let segments = conversation.map { line -> Segment in
            var s = Segment(original: line.original, translated: line.translated, recognizedAt: line.recognizedAt)
            s.translatedAt = line.translatedAt
            s.spokenAt = line.spokenAt
            s.failed = line.failed
            s.side = line.side.rawValue
            s.via = line.via.rawValue
            s.author = line.author
            s.speechEndedAt = line.speechEndedAt
            return s
        }
        let record = SessionRecord(id: sessionID, startedAt: sessionStartedAt, appName: targetName,
                                   appBundleIdentifier: targetBundle, sourceLocale: myLocaleID, targetLanguage: theirLocaleID,
                                   segments: segments, audioFile: audioFile, kind: SessionRecord.liveKind)
        onArchive?(record)
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

    private func heard(_ text: String, side: Side, via: Via = .voice, author: String? = nil) {
        guard phase == .running else { return }
        var line = Line(side: side, via: via, author: author, original: text, recognizedAt: Date())
        if via == .voice { line.speechEndedAt = quietSince[side] ?? loudAt[side] }
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
        lines[i].translatedAt = Date()
        let via = lines[i].via
        switch lines[i].side {
        case .me:
            if sendChat || via == .typed { queueForChat(text) }
            guard sendAudio, via == .voice else { return }
            // Into the call, in their language.
            let voice = AVSpeechSynthesisVoice(identifier: voiceForThemID)
                ?? Self.voices(for: theirLocaleID).first { !VoiceSynthesisManager.isPersonal($0) }
            Task { [speaker] in
                let buffers = await LiveAudio.render(text, voice: voice)
                await speaker?.enqueue(buffers) { Task { @MainActor [weak self] in self?.spoke(id) } }
            }
        case .them:
            guard via == .voice || speakChat else { return }
            // In your headphones, in your language.
            myVoice.voiceIdentifier = voiceForMeID.isEmpty ? nil : voiceForMeID
            myVoice.language = myLocaleID
            myVoice.speak(text, segmentID: id)
        }
    }

    // MARK: Chat (the Meet extension, through LiveMonitorServer)

    /// You typed a message in MacDub: translated into their language and sent to the chat.
    func type(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        heard(text, side: .me, via: .typed)
    }

    /// Someone wrote in the call's chat.
    func chatReceived(_ text: String, author: String?) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard phase == .running, translateChat, !text.isEmpty else { return }
        if let i = sentToChat.firstIndex(of: text) { sentToChat.remove(at: i); return }   // our own message
        heard(text, side: .them, via: .chat, author: author)
    }

    /// Messages for the extension to post, oldest first; asking also marks it connected.
    func takeChatOutbox() -> [String] {
        lastChatPoll = Date()
        if !chatConnected { chatConnected = true }
        let messages = outbox
        outbox.removeAll()
        return messages
    }

    /// Called now and then: the extension stopped asking.
    func checkChatConnection() {
        if chatConnected, Date().timeIntervalSince(lastChatPoll) > 5 { chatConnected = false }
    }

    private func queueForChat(_ text: String) {
        outbox.append(text)
        sentToChat.append(text)
        if sentToChat.count > 50 { sentToChat.removeFirst(sentToChat.count - 50) }
    }

    private func spoke(_ id: UUID) {
        if let i = lines.firstIndex(where: { $0.id == id }) { lines[i].spokenAt = Date() }
    }

    private func level(mic peak: Float? = nil, call: Float? = nil) {
        let now = Date()
        if let peak {
            track(.me, loud: peak > 0.02, at: now)
            if now.timeIntervalSince(lastMicLevel) > 0.066 { micLevel = peak; lastMicLevel = now }
        }
        if let call {
            track(.them, loud: call > 0.02, at: now)
            if now.timeIntervalSince(lastCallLevel) > 0.066 { callLevel = call; lastCallLevel = now }
        }
    }

    /// Silence starts after 0.3 s without sound; the sentence ended when it started.
    private func track(_ side: Side, loud: Bool, at now: Date) {
        if loud {
            loudAt[side] = now
            quietSince[side] = nil
            if !speaking.contains(side) { speaking.insert(side) }
        } else if quietSince[side] == nil, let last = loudAt[side], now.timeIntervalSince(last) > 0.3 {
            quietSince[side] = last
            if speaking.contains(side), (partial[side] ?? "").isEmpty { speaking.remove(side) }
        }
    }

    private func setPartial(_ text: String, side: Side) {
        guard phase == .running else { return }
        let text = text.trimmingCharacters(in: .whitespaces)
        if partial[side] != text { partial[side] = text }
        if text.isEmpty, quietSince[side] != nil { speaking.remove(side) }
    }

    private struct LiveError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}
