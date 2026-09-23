import MacDubCore
import Foundation
import AppKit
import SwiftUI
import Combine
import CoreGraphics
import Speech
import Translation
import AVFAudio

/// Owns the three pipeline stages and exposes everything the UI binds to.
///
/// capture (ScreenCaptureKit) ─▶ speech + translation (Speech, Translation) ─▶ voice (AVFAudio)
@MainActor
final class AppState: ObservableObject {
    /// Single instance shared by the SwiftUI scenes and the AppKit menu bar controller.
    static let shared = AppState()
    static let mainWindowID = "main"

    enum Phase: Equatable { case idle, starting, running, stopping }

    struct Capabilities: Equatable {
        var screenRecording = false
        var speechAuthorization: SFSpeechRecognizerAuthorizationStatus = .notDetermined
        var sourceOnDevice = false
        var translationStatus: LanguageAvailability.Status? = nil
        var voiceAvailable = false
    }

    // MARK: Published state

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var targets: [CaptureTarget] = []
    @Published var selectedTargetID: String?
    @Published private(set) var capabilities = Capabilities()
    @Published private(set) var sourceLocales: [Locale] = []
    @Published private(set) var targetLanguages: [Locale.Language] = []
    @Published private(set) var voices: [AVSpeechSynthesisVoice] = []

    @Published private(set) var partialText = ""
    @Published private(set) var segments: [Segment] = []
    /// Audio level lives in its own observable so 20 Hz updates don't re-render the settings form.
    let meter = LiveMeter()
    @Published private(set) var ttsBacklog = 0
    @Published private(set) var nowSpeaking: String?

    @Published var errorMessage: String?
    @Published var errorSuggestion: String?
    /// Non-fatal notice shown in the footer (e.g. fell back to ScreenCaptureKit).
    @Published private(set) var notice: String?
    /// Which capture engine is actually running ("tap" / "sck"), nil when idle.
    @Published private(set) var activeEngine: String?
    /// Which recognition engine is actually running ("legacy" / "analyzer"), nil when idle.
    @Published private(set) var activeRecognitionEngine: String?
    /// Seconds since the captured app last produced audible sound (nil when idle).
    @Published private(set) var silentFor: Double?
    private var lastAudibleAt = Date()
    private var silenceTimer: Timer?
    private var silenceNoticed = false

    /// Saved sessions (newest first); refreshed after each stop and from the History window.
    @Published private(set) var sessions: [SessionRecord] = []
    private let hotKeys = GlobalHotKeys()
    /// Last minutes of captured audio for MCP `get_audio_snippet`.
    private let ring = AudioRingBuffer(capacitySeconds: 120)
    /// Writes the original audio of the session to ~/.macdub/audio for History playback/export.
    private let recorder = SessionAudioRecorder()
    /// Id of the session being dubbed (also the name of its audio file); new when the transcript is empty at Start.
    private(set) var currentSessionID = UUID().uuidString
    /// Bytes under ~/.macdub (recorded audio); refreshed by `refreshStorageSize()`.
    @Published private(set) var storageSize: Int64?
    /// The MCP helper running in HTTP mode, when enabled in settings.
    private var mcpHTTPProcess: Process?
    @Published private(set) var mcpHTTPStatus: String?

    struct LatencyStats: Equatable {
        var samples = 0
        /// Mean seconds from sentence cut to translation returned.
        var translation: Double = 0
        /// Mean seconds from sentence cut to the voice starting to speak it.
        var spoken: Double = 0
        var lastSpoken: Double = 0
    }
    @Published private(set) var latency = LatencyStats()

    /// Set by `FloatingSubtitlesView` on appear/disappear.
    @Published var isSubtitleBarVisible = false
    /// Section shown in the main window's sidebar.
    @Published var section: AppSection = .dub
    /// Session to open in History from outside the view (UI snapshots); the view adopts it.
    @Published var historySelection: String?

    /// Where the voice is right now, for karaoke-style highlighting.
    struct SpeakingPosition: Equatable {
        let segmentID: UUID
        /// Character range (UTF-16, as `AVSpeechSynthesizer` reports it) of the current word.
        let word: NSRange
    }
    @Published private(set) var speaking: SpeakingPosition?
    /// Window actions captured from the SwiftUI environment (set by `ContentView`), so AppKit
    /// code (menu bar, dock reopen) can open scenes too.
    var openWindowAction: OpenWindowAction?
    var dismissWindowAction: DismissWindowAction?

    let settings = Settings()
    let translation = TranslationBridge()

    // MARK: Pipeline

    private let capture = AudioCaptureManager()
    private let tap = ProcessTapCaptureManager()
    private let speech: SpeechAndTranslationManager
    private let voice = VoiceSynthesisManager()
    private var cancellables = Set<AnyCancellable>()
    private var lastLevelUpdate = Date.distantPast
    private let maxSegments = 400

    init() {
        speech = SpeechAndTranslationManager(translator: translation)
        wireCallbacks()
        observeSettings()
        observeLiveState()
        observeCommands()
        configureHotKeys()
        configureMCPHTTP()
        MCPInstaller.recordAppLocation()
        MacDubPaths.migrateLegacyDirectory()
        MacDubPaths.removeStrayPartFiles()
        sessions = SessionStore.list()
        Task { await bootstrap() }
    }

    // MARK: Global hot keys

    private func configureHotKeys() {
        hotKeys.onAction = { [weak self] action in
            switch action {
            case .toggleDubbing: self?.toggle()
            case .toggleSubtitleBar: self?.toggleSubtitleBar()
            }
        }
        settings.$globalHotKeys.removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] on in on ? self?.hotKeys.register() : self?.hotKeys.unregister() }
            .store(in: &cancellables)
    }

    // MARK: Silence watchdog

    private func startSilenceWatchdog() {
        lastAudibleAt = Date()
        silenceNoticed = false
        silentFor = 0
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.checkSilence() }
        }
    }

    private func stopSilenceWatchdog() {
        silenceTimer?.invalidate()
        silenceTimer = nil
        silentFor = nil
    }

    private func checkSilence() {
        guard phase == .running else { return }
        let quiet = Date().timeIntervalSince(lastAudibleAt)
        silentFor = quiet
        let timeout = settings.silenceTimeout
        guard timeout > 0, quiet >= timeout else {
            if silenceNoticed, quiet < 2 { silenceNoticed = false; notice = nil }
            return
        }
        if settings.stopOnSilence {
            Log.app.notice("No audio for \(Int(quiet)) s — stopping")
            notice = LF("Stopped: %@ has been silent for %lld s.", selectedTarget?.name ?? L("the app"), Int(quiet))
            Task { await stop() }
        } else if !silenceNoticed {
            silenceNoticed = true
            notice = LF("%@ has been silent for %lld s.", selectedTarget?.name ?? L("the app"), Int(quiet))
        }
    }

    // MARK: MCP over HTTP (child helper process)

    private func configureMCPHTTP() {
        settings.$mcpHTTPEnabled.combineLatest(settings.$mcpHTTPPort)
            .removeDuplicates { $0 == $1 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled, port in
                self?.stopMCPHTTP()
                if enabled { self?.startMCPHTTP(port: port) }
            }
            .store(in: &cancellables)
    }

    private func startMCPHTTP(port: Int) {
        guard MCPInstaller.isBundled else {
            mcpHTTPStatus = L("MCP helper not bundled (run from build/MacDub.app).")
            return
        }
        let process = Process()
        process.executableURL = MCPInstaller.serverURL
        process.arguments = ["--http", String(port)]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] p in
            Task { @MainActor [weak self] in
                guard let self, self.mcpHTTPProcess === p else { return }
                self.mcpHTTPProcess = nil
                self.mcpHTTPStatus = LF("MCP HTTP server stopped (exit %lld).", Int(p.terminationStatus))
            }
        }
        do {
            try process.run()
            mcpHTTPProcess = process
            mcpHTTPStatus = LF("Serving http://127.0.0.1:%lld/mcp", port)
            Log.app.info("MCP HTTP server started on port \(port)")
        } catch {
            mcpHTTPStatus = error.localizedDescription
        }
    }

    private func stopMCPHTTP() {
        guard let p = mcpHTTPProcess else { return }
        mcpHTTPProcess = nil
        p.terminate()
        mcpHTTPStatus = nil
    }

    func shutdown() {
        stopMCPHTTP()
    }

    // MARK: Session history

    func refreshSessions() {
        sessions = SessionStore.list()
    }

    func deleteSession(_ record: SessionRecord) {
        try? SessionStore.delete(id: record.id)
        refreshSessions()
        refreshStorageSize()
    }

    func deleteAllSessions() {
        do { try SessionStore.deleteAll() } catch {
            present(message: LF("Could not delete the sessions: %@", error.localizedDescription), suggestion: nil)
        }
        refreshSessions()
        refreshStorageSize()
    }

    /// Size of ~/.macdub, computed off the main thread (it walks the directory).
    func refreshStorageSize() {
        let dir = MacDubPaths.dataDirectory
        Task.detached(priority: .utility) {
            let size = MacDubPaths.directorySize(dir)
            await MainActor.run { self.storageSize = size }
        }
    }

    /// Erases preferences, saved sessions, recorded audio and the live state, then relaunches
    /// MacDub as if freshly installed. Registrations in Claude Code/Desktop/Codex are left alone:
    /// they point at a launcher the app rewrites on its next start.
    func factoryReset() async {
        await stop()
        stopMCPHTTP()
        recorder.reset()
        for dir in MacDubPaths.allDataDirectories { try? FileManager.default.removeItem(at: dir) }
        if let bundleID = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleID)
        }
        UserDefaults.standard.synchronize()
        Log.app.notice("Factory reset done; relaunching")
        relaunch()
    }

    /// Privacy grants MacDub asks for: Screen & System Audio Recording (ScreenCaptureKit), System
    /// Audio Recording Only (the Core Audio tap) and Speech Recognition.
    static let privacyServices = ["ScreenCapture", "AudioCapture", "SpeechRecognition"]

    /// Forgets MacDub's privacy grants (`tccutil reset`, no admin rights needed for the app's own
    /// bundle id) and relaunches, so macOS asks for each one again. Useful when a grant stops
    /// being honoured after a rebuild changed the app's signature.
    func resetPermissionsAndRelaunch() async {
        await stop()
        let bundleID = Bundle.main.bundleIdentifier ?? "com.lordbasex.MacDub"
        for service in Self.privacyServices {
            let tcc = Process()
            tcc.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            tcc.arguments = ["reset", service, bundleID]
            do {
                try tcc.run()
                tcc.waitUntilExit()
                Log.app.notice("tccutil reset \(service, privacy: .public): \(tcc.terminationStatus)")
            } catch {
                Log.app.error("tccutil reset \(service, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        relaunch()
    }

    /// Quits and starts MacDub again. The new copy is launched through LaunchServices (a helper
    /// process of ours would be killed along with this app) and told which process it replaces,
    /// so it waits for this one to exit instead of taking it for another instance (`MacDubMain`).
    func relaunch() {
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-n", Bundle.main.bundlePath, "--args", MacDubMain.relaunchArgument, String(getpid())]
        try? open.run()
        open.waitUntilExit()
        NSApp.terminate(nil)
    }

    /// Saves the transcript (and the recorded audio, if any) under `currentSessionID`. A session
    /// that is stopped and resumed is saved again under the same id, so History shows it once.
    private func archiveCurrentSession(audioURL: URL?) {
        guard settings.saveSessions, !segments.isEmpty else { return }
        let record = SessionRecord(id: currentSessionID, startedAt: sessionStartedAt, appName: selectedTarget?.name,
                                   appBundleIdentifier: selectedTarget?.bundleIdentifier,
                                   sourceLocale: settings.sourceLocaleID, targetLanguage: settings.targetLanguageID,
                                   segments: segments, audioFile: audioURL?.lastPathComponent)
        do {
            try SessionStore.save(record)
            refreshSessions()
            refreshStorageSize()
        } catch {
            Log.app.error("Could not save session: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Live state (for the MCP server) & remote commands

    private func observeLiveState() {
        // Anything the MCP server may want to read → rewrite the snapshot, at most ~3×/s.
        let triggers: [AnyPublisher<Void, Never>] = [
            $segments.map { _ in () }.eraseToAnyPublisher(),
            $phase.map { _ in () }.eraseToAnyPublisher(),
            $partialText.map { _ in () }.eraseToAnyPublisher(),
            $targets.map { _ in () }.eraseToAnyPublisher(),
            $selectedTargetID.map { _ in () }.eraseToAnyPublisher(),
            $voices.map { _ in () }.eraseToAnyPublisher(),
            $latency.map { _ in () }.eraseToAnyPublisher(),
            settings.$voiceIdentifier.map { _ in () }.eraseToAnyPublisher(),
            settings.$speakTranslation.map { _ in () }.eraseToAnyPublisher(),
            settings.$originalVolume.map { _ in () }.eraseToAnyPublisher(),
            settings.$duckOnlyWhileSpeaking.map { _ in () }.eraseToAnyPublisher(),
            settings.$sourceLocaleID.map { _ in () }.eraseToAnyPublisher(),
            settings.$targetLanguageID.map { _ in () }.eraseToAnyPublisher(),
        ]
        Publishers.MergeMany(triggers)
            .throttle(for: .milliseconds(300), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] in self?.writeLiveState() }
            .store(in: &cancellables)
    }

    private func writeLiveState() {
        let phaseName: String
        switch phase {
        case .idle: phaseName = "idle"
        case .starting: phaseName = "starting"
        case .running: phaseName = "running"
        case .stopping: phaseName = "stopping"
        }
        var state = LiveState(
            phase: phaseName,
            target: selectedTarget.map { LiveState.Target(name: $0.name, bundleIdentifier: $0.bundleIdentifier) },
            availableTargets: targets.map { LiveState.Target(name: $0.name, bundleIdentifier: $0.bundleIdentifier) },
            sourceLocale: settings.sourceLocaleID,
            targetLanguage: settings.targetLanguageID,
            sessionStart: sessionStartedAt,
            partial: partialText,
            segments: segments.map(LiveState.SegmentDTO.init))
        state.translationLatency = latency.translation
        state.speechLatency = latency.spoken
        state.captureEngine = activeEngine
        state.recognitionEngine = activeRecognitionEngine
        state.silentFor = silentFor
        state.voiceIdentifier = settings.voiceIdentifier.isEmpty ? nil : settings.voiceIdentifier
        state.speakTranslation = settings.speakTranslation
        state.originalVolume = settings.originalVolume
        state.duckOnlyWhileSpeaking = settings.duckOnlyWhileSpeaking
        state.availableVoices = voices.map {
            LiveState.Voice(identifier: $0.identifier, name: $0.name, language: $0.language,
                            quality: VoiceSynthesisManager.qualityLabel($0.quality))
        }
        state.availableSourceLocales = sourceLocales.filter(SpeechAndTranslationManager.supportsOnDevice).map(\.identifier)
        state.availableTargetLanguages = targetLanguages.map(\.minimalIdentifier)
        do {
            try LiveStateStore.write(state)
        } catch {
            Log.app.error("live.json: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func observeCommands() {
        DistributedNotificationCenter.default().addObserver(
            forName: MacDubCommand.notificationName, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, let raw = note.userInfo?["action"] as? String,
                  let action = MacDubCommand.Action(rawValue: raw) else { return }
            Log.app.info("Remote command: \(raw, privacy: .public)")
            Task { @MainActor in
                switch action {
                case .start:
                    // Optional target in the same command, so selection and start can't race.
                    if let bundle = note.userInfo?["bundleIdentifier"] as? String {
                        await self.selectTarget(bundleIdentifier: bundle)
                    }
                    await self.start()
                case .stop: await self.stop()
                case .clearTranscript: self.clearTranscript()
                case .selectTarget:
                    if let bundle = note.userInfo?["bundleIdentifier"] as? String {
                        await self.selectTarget(bundleIdentifier: bundle)
                    }
                case .setLanguages:
                    // Languages are bound to the running engines; only honoured while idle.
                    guard self.phase == .idle else { return }
                    if let s = note.userInfo?["sourceLocale"] as? String, self.sourceLocales.contains(where: { $0.identifier == s }) {
                        self.settings.sourceLocaleID = s
                    }
                    if let t = note.userInfo?["targetLanguage"] as? String, self.targetLanguages.contains(where: { $0.minimalIdentifier == t }) {
                        self.settings.targetLanguageID = t
                    }
                case .setVoice:
                    if let id = note.userInfo?["voiceIdentifier"] as? String, self.voices.contains(where: { $0.identifier == id }) {
                        self.settings.voiceIdentifier = id
                    }
                case .setSpeak:
                    if let v = note.userInfo?["enabled"] as? String { self.settings.speakTranslation = (v == "true") }
                case .setOriginalVolume:
                    if let v = note.userInfo?["level"] as? String, let level = Double(v) {
                        self.settings.originalVolume = min(1, max(0, level))
                    }
                    if let d = note.userInfo?["duckOnlyWhileSpeaking"] as? String { self.settings.duckOnlyWhileSpeaking = (d == "true") }
                case .snapshotUI:
                    guard let path = note.userInfo?["path"] as? String else { return }
                    await UISnapshots.capture(to: URL(fileURLWithPath: path), label: note.userInfo?["label"] as? String ?? "ui", state: self)
                case .exportAudio:
                    // Any local process can post this command: write .wav files only, so it can't
                    // be used to replace other files with a recording.
                    guard let path = note.userInfo?["path"] as? String,
                          URL(fileURLWithPath: path).pathExtension.lowercased() == "wav" else { return }
                    let seconds = Double(note.userInfo?["seconds"] as? String ?? "") ?? 15
                    let url = URL(fileURLWithPath: path)
                    do {
                        try self.ring.writeWAV(to: url, lastSeconds: min(max(1, seconds), self.settings.audioBufferSeconds))
                        Log.app.info("Audio snippet written to \(url.lastPathComponent, privacy: .public)")
                    } catch {
                        // Leave an error marker the MCP server can report instead of timing out.
                        try? error.localizedDescription.write(to: url.appendingPathExtension("error"), atomically: true, encoding: .utf8)
                    }
                }
            }
        }
    }

    var isBusy: Bool { phase == .starting || phase == .stopping }
    var selectedTarget: CaptureTarget? { targets.first { $0.id == selectedTargetID } }

    var sourceLanguageForTranslation: Locale.Language {
        Locale.Language(identifier: settings.sourceLocale.language.languageCode?.identifier ?? settings.sourceLocaleID)
    }

    // MARK: Bootstrap / discovery

    private func bootstrap() async {
        sourceLocales = SpeechAndTranslationManager.allLocales()
        targetLanguages = await TranslationCatalog.supportedTargetLanguages()
        await refreshTargets()
        await refreshCapabilities()
    }

    func refreshTargets() async {
        capabilities.screenRecording = CGPreflightScreenCaptureAccess()
        do {
            let list = [CaptureTarget.system] + (try await AudioCaptureManager.availableTargets())
            targets = list
            if selectedTarget == nil {
                selectedTargetID = list.first { $0.bundleIdentifier == settings.lastTargetBundleID }?.id
                    ?? list.first { $0.bundleIdentifier == "com.apple.Safari" || $0.bundleIdentifier == "com.google.Chrome" }?.id
            }
            capabilities.screenRecording = true
        } catch {
            targets = []
            capabilities.screenRecording = CGPreflightScreenCaptureAccess()
            Log.app.error("Shareable content: \(error.localizedDescription, privacy: .public)")
        }
    }

    func refreshCapabilities() async {
        // Ask for real this time: "is there an on-device model for this language?" is memoised
        // because asking is an XPC call, and this is exactly where it must be forgotten — the
        // user may have just downloaded a dictation language.
        SFSpeechEngine.invalidateOnDeviceCache()
        capabilities.speechAuthorization = SpeechAndTranslationManager.authorizationStatus()
        capabilities.sourceOnDevice = SpeechAndTranslationManager.supportsOnDevice(settings.sourceLocale)
        capabilities.translationStatus = await TranslationCatalog.status(from: sourceLanguageForTranslation, to: settings.targetLanguage)
        refreshVoices()
    }

    /// Re-query the system voice list (after the user downloads voices in System Settings).
    func reloadVoices() {
        refreshVoices()
        Log.voice.info("Voices reloaded: \(self.voices.count) for \(self.settings.targetLanguageCode, privacy: .public)")
    }

    private func refreshVoices() {
        voices = VoiceSynthesisManager.voices(forLanguageCode: settings.targetLanguageCode)
        capabilities.voiceAvailable = !voices.isEmpty
        if !voices.contains(where: { $0.identifier == settings.voiceIdentifier }) {
            settings.voiceIdentifier = voices.first?.identifier ?? ""
        }
    }

    /// Prompts for Screen Recording. macOS only honours the grant after the app is relaunched.
    func requestScreenRecording() {
        if !CGRequestScreenCaptureAccess() {
            SystemSettings.open(SystemSettings.screenRecording)
        }
        Task { await refreshTargets() }
    }

    func requestSpeechAuthorization() {
        Task {
            _ = await SpeechAndTranslationManager.requestAuthorization()
            await refreshCapabilities()
        }
    }

    /// Configures the translation session for the current pair and triggers the model download UI.
    func prepareTranslation() {
        translation.configure(source: sourceLanguageForTranslation, target: settings.targetLanguage)
        translation.prepare()
        Task {
            try? await Task.sleep(for: .seconds(2))
            await refreshCapabilities()
        }
    }

    func testVoice() {
        applyVoiceSettings()
        // Spoken in the *target* language regardless of the interface language.
        let samples = [
            "es": "Hola, esta es la voz que usará MacDub.",
            "pt": "Olá, esta é a voz que o MacDub vai usar.",
            "fr": "Bonjour, voici la voix que MacDub utilisera.",
            "de": "Hallo, das ist die Stimme, die MacDub verwenden wird.",
            "it": "Ciao, questa è la voce che userà MacDub.",
            "ja": "こんにちは、これはMacDubが使う声です。",
            "zh": "你好，这是 MacDub 将使用的声音。",
        ]
        voice.speak(samples[settings.targetLanguageCode] ?? "Hello, this is the voice MacDub will use.")
    }

    func skipBacklog() { voice.skipBacklog() }

    /// Selects a capture target by bundle id, refreshing the app list if it was launched after
    /// the list was built. Returns false when the app is not running.
    @discardableResult
    func selectTarget(bundleIdentifier bundle: String) async -> Bool {
        if !targets.contains(where: { $0.bundleIdentifier == bundle }) { await refreshTargets() }
        guard let t = targets.first(where: { $0.bundleIdentifier == bundle }) else {
            Log.app.notice("selectTarget: \(bundle, privacy: .public) is not running")
            return false
        }
        selectedTargetID = t.id
        return true
    }

    // MARK: Menu bar mode

    @Published var launchAtLogin = LaunchAtLogin.isEnabled {
        didSet {
            guard launchAtLogin != oldValue else { return }
            if let error = LaunchAtLogin.set(launchAtLogin) {
                present(message: error, suggestion: L("Open System Settings › General › Login Items and allow MacDub."))
                launchAtLogin = LaunchAtLogin.isEnabled
            }
        }
    }

    func applyDockIconPolicy() {
        NSApp.setActivationPolicy(settings.hideDockIcon ? .accessory : .regular)
        if !settings.hideDockIcon { NSApp.activate(ignoringOtherApps: true) }
    }

    private var autoStartTimer: Timer?

    /// Polls the selected app's audio output while idle and starts dubbing when it begins to play.
    private func configureAutoStart() {
        autoStartTimer?.invalidate()
        autoStartTimer = nil
        guard settings.autoStartWhenAudio else { return }
        autoStartTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.phase == .idle, self.errorMessage == nil, let target = self.selectedTarget else { return }
                if ProcessTapCaptureManager.isProducingAudio(target) {
                    Log.app.info("\(target.name, privacy: .public) started playing audio — auto-starting")
                    await self.start()
                }
            }
        }
    }

    // MARK: Windows

    func showMainWindow() {
        // The window is hidden, not closed, when the user closes it (see MainWindowBehavior);
        // bring it back directly, and let SwiftUI create it if it does not exist yet.
        if let window = mainWindow {
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindowAction?.callAsFunction(id: Self.mainWindowID)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    var mainWindow: NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue.hasPrefix(Self.mainWindowID) == true || $0.title == "MacDub" }
    }

    /// The translation session lives in the main window's view tree and does not come back by
    /// itself if it was ever cancelled; when the window (re)appears with a configuration but no
    /// running session, restart it.
    func ensureTranslationSession() {
        if translation.configuration != nil, translation.status == .idle {
            translation.prepare()
        }
    }

    func showHistory() {
        refreshSessions()
        section = .history
        showMainWindow()
    }

    /// Opens the Settings window (⌘,) from AppKit code paths (menu bar).
    func showSettings() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    func toggleSubtitleBar() {
        if isSubtitleBarVisible {
            dismissWindowAction?.callAsFunction(id: FloatingSubtitlesView.windowID)
        } else {
            openWindowAction?.callAsFunction(id: FloatingSubtitlesView.windowID)
        }
    }

    func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        let credits = NSAttributedString(
            string: L("Real-time, fully offline dubbing for macOS.") + "\nScreenCaptureKit · Speech · Translation · AVFAudio\n\n"
                + LF("Created by %@", "Federico Pereira <lord.basex@gmail.com>")
                + "\nMIT License — github.com/lordbasex/macdub",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "MacDub",
            .credits: credits,
        ])
    }

    /// Empties the transcript and starts a new session: new id, new clock origin, new audio file.
    /// While dubbing, the recording continues into the new file from this moment; the audio of
    /// the discarded sentences is thrown away (unless it belongs to a session already archived).
    func clearTranscript() {
        segments.removeAll()
        partialText = ""
        let previousID = currentSessionID
        currentSessionID = UUID().uuidString
        sessionStartedAt = Date()
        recorder.discard(keepFinishedTake: SessionStore.exists(id: previousID))
        if phase == .running, settings.saveSessions, settings.recordAudio {
            recorder.begin(url: SessionStore.audioURL(for: currentSessionID), sessionStart: sessionStartedAt)
        }
    }

    // MARK: Export

    /// When the current (or last) session started; SRT offsets are relative to it.
    private(set) var sessionStartedAt = Date()

    var exportMetadata: TranscriptExporter.Metadata {
        TranscriptExporter.Metadata(appName: selectedTarget?.name, sourceLanguage: settings.sourceLocaleID,
                                    targetLanguage: settings.targetLanguageID)
    }

    /// The whole transcript as Markdown (what the summary feature and the MCP server hand to an LLM).
    func transcriptMarkdown() -> String {
        TranscriptExporter.render(segments, format: .md, content: .both, sessionStart: sessionStartedAt, metadata: exportMetadata)
    }

    func exportTranscript(format: TranscriptExporter.Format, content: TranscriptExporter.Content = .both) {
        guard !segments.isEmpty else { return }
        let panel = NSSavePanel()
        panel.title = L("Export Transcript")
        panel.nameFieldStringValue = "macdub-transcript-\(SessionRecord.exportStamp(sessionStartedAt)).\(format.fileExtension)"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = TranscriptExporter.render(segments, format: format, content: content, sessionStart: sessionStartedAt, metadata: exportMetadata)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            Log.app.info("Exported \(self.segments.count) segments to \(url.lastPathComponent, privacy: .public)")
        } catch {
            present(message: LF("Could not save the file: %@", error.localizedDescription), suggestion: nil)
        }
    }

    // MARK: Start / stop

    func toggle() {
        Task {
            if phase == .running { await stop() } else if phase == .idle { await start() }
        }
    }

    func start() async {
        guard phase == .idle else { return }
        guard let target = selectedTarget else {
            present(message: L("Choose an application to capture first."), suggestion: nil)
            return
        }
        phase = .starting
        clearError()

        do {
            // 1. Permissions
            if !CGPreflightScreenCaptureAccess() {
                _ = CGRequestScreenCaptureAccess()
                throw MacDubError.screenRecordingDenied
            }
            var auth = SpeechAndTranslationManager.authorizationStatus()
            if auth == .notDetermined {
                auth = await SpeechAndTranslationManager.requestAuthorization()
                try ensureStillStarting()
            }
            switch auth {
            case .authorized: break
            case .restricted: throw MacDubError.speechRecognitionRestricted
            default: throw MacDubError.speechRecognitionDenied
            }

            // 2. Translation model
            let status = await TranslationCatalog.status(from: sourceLanguageForTranslation, to: settings.targetLanguage)
            try ensureStillStarting()
            capabilities.translationStatus = status
            if status == .unsupported {
                throw MacDubError.translationUnsupported(source: sourceLanguageForTranslation.minimalIdentifier,
                                                         target: settings.targetLanguageID)
            }
            translation.configure(source: sourceLanguageForTranslation, target: settings.targetLanguage)

            // 3. Voice
            refreshVoices()
            if settings.speakTranslation, voices.isEmpty {
                throw MacDubError.noVoiceForLanguage(settings.targetLanguageID)
            }
            applyVoiceSettings()

            // 4. Recognition
            speech.silenceFlushInterval = settings.silenceFlushInterval
            let engineKind = RecognitionEngineKind(rawValue: settings.recognitionEngine) ?? .auto
            try speech.start(sourceLocale: settings.sourceLocale, engineKind: engineKind)
            activeRecognitionEngine = speech.engineKind.rawValue

            // 5. Capture — last, so audio only flows once everything downstream is ready.
            ring.clear()
            let keepAudio = settings.audioBufferSeconds > 0
            // An empty transcript means a new session: new id, new clock origin. Otherwise this is
            // a resume and the recorder pads the gap with silence so cues and audio stay aligned.
            if segments.isEmpty {
                sessionStartedAt = Date()
                currentSessionID = UUID().uuidString
                recorder.reset()
            }
            let recording = settings.saveSessions && settings.recordAudio
            if recording {
                recorder.begin(url: SessionStore.audioURL(for: currentSessionID), sessionStart: sessionStartedAt)
            }
            let sink: (AVAudioPCMBuffer) -> Void = { [speech, ring, recorder] buffer in
                speech.append(buffer)
                if keepAudio { ring.append(buffer) }
                if recording { recorder.append(buffer) }
            }
            notice = nil
            if settings.usesProcessTap {
                do {
                    try tap.start(target: target, onBuffer: sink)
                    activeEngine = "tap"
                    updatePassthroughGain()
                } catch {
                    // The tap needs the app to have an audio process already; fall back so the user
                    // still gets a dub, just without the lowered original.
                    Log.capture.notice("Process tap unavailable (\(error.localizedDescription, privacy: .public)); using ScreenCaptureKit")
                    notice = LF("Original audio can't be lowered: %@ Using ScreenCaptureKit.", error.localizedDescription)
                    try await capture.start(target: target, onBuffer: sink)
                    activeEngine = "sck"
                }
            } else {
                try await capture.start(target: target, onBuffer: sink)
                activeEngine = "sck"
            }
            try ensureStillStarting()

            settings.lastTargetBundleID = target.bundleIdentifier
            latency = LatencyStats()
            startSilenceWatchdog()
            phase = .running
            Log.app.info("Pipeline running (\(self.activeEngine ?? "-", privacy: .public)): \(target.name, privacy: .public) \(self.settings.sourceLocaleID, privacy: .public) → \(self.settings.targetLanguageID, privacy: .public)")
        } catch is StartCancelled {
            // stop() tore the pipeline down while this start() awaited; stop what started since,
            // without archiving the session a second time.
            await capture.stop()
            tap.stop()
            speech.stop()
            activeEngine = nil
            activeRecognitionEngine = nil
            Log.app.info("Start cancelled by a stop")
        } catch {
            present(error)
            await teardown()
        }
    }

    /// A stop() (menu, hot key, MCP) can arrive while start() awaits permissions, the translation
    /// model or the capture engine; start() must not then carry on and mark a torn-down pipeline
    /// as running.
    private struct StartCancelled: Error {}
    private func ensureStillStarting() throws {
        if phase != .starting { throw StartCancelled() }
    }

    func stop() async {
        guard phase == .running || phase == .starting else { return }
        await teardown()
    }

    private func teardown() async {
        phase = .stopping
        stopSilenceWatchdog()
        await capture.stop()
        tap.stop()
        speech.stop()
        voice.stop()
        partialText = ""
        meter.level = 0
        activeEngine = nil
        activeRecognitionEngine = nil
        speaking = nil
        // Let in-flight translations land before archiving (the last flush happens at stop).
        let deadline = Date().addingTimeInterval(2.5)
        while segments.contains(where: { $0.translated == nil && !$0.failed }), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(150))
        }
        let audioURL: URL? = await withCheckedContinuation { continuation in
            recorder.finish { continuation.resume(returning: $0) }
        }
        archiveCurrentSession(audioURL: audioURL)
        phase = .idle
        Log.app.info("Pipeline stopped")
    }

    // MARK: Wiring

    private func wireCallbacks() {
        let levelSink: (Float) -> Void = { [weak self] level in
            Task { @MainActor [weak self] in
                guard let self, Date().timeIntervalSince(self.lastLevelUpdate) > 0.05 else { return }
                self.lastLevelUpdate = Date()
                self.meter.level = level
                if level > 0.02 { self.lastAudibleAt = Date() }
            }
        }
        speech.onEngineChanged = { [weak self] kind in
            Task { @MainActor [weak self] in
                self?.activeRecognitionEngine = kind.rawValue
                self?.notice = L("SpeechAnalyzer failed; switched to SFSpeechRecognizer for this session.")
            }
        }
        capture.onLevel = levelSink
        tap.onLevel = levelSink
        capture.onStreamStopped = { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self, self.phase == .running else { return }
                self.present(MacDubError.captureStopped(error.localizedDescription))
                await self.teardown()
            }
        }

        speech.onPartial = { [weak self] text in
            Task { @MainActor [weak self] in self?.partialText = text }
        }
        speech.onSegmentRecognized = { [weak self] segment in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.segments.append(segment)
                if self.segments.count > self.maxSegments { self.segments.removeFirst(self.segments.count - self.maxSegments) }
            }
        }
        speech.onSegmentTranslated = { [weak self] segment in
            Task { @MainActor [weak self] in
                guard let self else { return }
                var segment = segment
                let age = Date().timeIntervalSince(segment.recognizedAt)
                let shouldSpeak = self.phase == .running && self.settings.speakTranslation && segment.translated != nil
                // Behind and this sentence is already stale: show it as a subtitle only.
                if shouldSpeak, self.ttsBacklog > 0, age > self.settings.maxSpokenLag {
                    Log.voice.notice("Skipping stale sentence (\(Int(age)) s old, backlog \(self.ttsBacklog))")
                    segment.skipped = true
                }
                if let i = self.segments.firstIndex(where: { $0.id == segment.id }) {
                    self.segments[i] = segment
                }
                if let t = segment.translationLatency {
                    Log.speech.info("Latency: translated in \(String(format: "%.2f", t), privacy: .public) s")
                }
                if shouldSpeak, !segment.skipped, let text = segment.translated {
                    self.applyVoiceSettings()
                    self.voice.speak(text, segmentID: segment.id)
                }
            }
        }
        speech.onFatalError = { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.present(error)
                await self.teardown()
            }
        }

        voice.onBacklogChanged = { [weak self] n in self?.ttsBacklog = n }
        voice.onSpeaking = { [weak self] text in
            self?.nowSpeaking = text
            self?.updatePassthroughGain()
        }
        voice.onSegmentStarted = { [weak self] id in
            guard let self, let i = self.segments.firstIndex(where: { $0.id == id }) else { return }
            self.segments[i].spokenAt = Date()
            self.recomputeLatency()
        }
        voice.onWordRange = { [weak self] id, range in
            guard let self else { return }
            if let range {
                self.speaking = SpeakingPosition(segmentID: id, word: range)
            } else if self.speaking?.segmentID == id {
                self.speaking = nil
            }
        }
    }

    /// Rolling mean over the last 10 spoken sentences.
    private func recomputeLatency() {
        let recent = segments.suffix(40).filter { $0.spokenAt != nil }.suffix(10)
        guard !recent.isEmpty else { return }
        var stats = LatencyStats()
        stats.samples = recent.count
        stats.spoken = recent.compactMap(\.speechLatency).reduce(0, +) / Double(recent.count)
        let translated = recent.compactMap(\.translationLatency)
        stats.translation = translated.isEmpty ? 0 : translated.reduce(0, +) / Double(translated.count)
        stats.lastSpoken = recent.last?.speechLatency ?? 0
        latency = stats
        Log.voice.info("Latency: spoken after \(String(format: "%.2f", stats.lastSpoken), privacy: .public) s (mean \(String(format: "%.2f", stats.spoken), privacy: .public) s, translation \(String(format: "%.2f", stats.translation), privacy: .public) s)")
    }

    /// Original-audio level under the dub (process tap engine only).
    private func updatePassthroughGain() {
        guard activeEngine == "tap" else { return }
        let base = Float(settings.originalVolume)
        if settings.duckOnlyWhileSpeaking {
            tap.passthroughGain = nowSpeaking == nil ? 1 : base
        } else {
            tap.passthroughGain = base
        }
    }

    private func observeSettings() {
        settings.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)

        settings.$sourceLocaleID.removeDuplicates().dropFirst()
            .sink { [weak self] _ in Task { await self?.refreshCapabilities() } }
            .store(in: &cancellables)

        settings.$targetLanguageID.removeDuplicates().dropFirst()
            .sink { [weak self] _ in Task { await self?.refreshCapabilities() } }
            .store(in: &cancellables)

        settings.$originalVolume.map { _ in () }
            .merge(with: settings.$duckOnlyWhileSpeaking.map { _ in () })
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.updatePassthroughGain() }
            .store(in: &cancellables)

        settings.$hideDockIcon.removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.applyDockIconPolicy() }
            .store(in: &cancellables)

        settings.$autoStartWhenAudio.removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.configureAutoStart() }
            .store(in: &cancellables)
    }

    private func applyVoiceSettings() {
        voice.voiceIdentifier = settings.voiceIdentifier.isEmpty ? nil : settings.voiceIdentifier
        voice.language = voices.first?.language ?? settings.targetLanguageID
        voice.rate = Float(settings.speechRate)
        voice.volume = Float(settings.volume)
        voice.maxBacklog = settings.maxBacklog
        voice.catchUpBoost = Float(settings.catchUpBoost)
    }

    // MARK: Errors

    private func present(_ error: Error) {
        let message = error.localizedDescription
        let suggestion = (error as? LocalizedError)?.recoverySuggestion
        present(message: message, suggestion: suggestion)
        Log.app.error("\(message, privacy: .public)")
    }

    func present(message: String, suggestion: String?) {
        errorMessage = message
        errorSuggestion = suggestion
    }

    func clearError() {
        errorMessage = nil
        errorSuggestion = nil
    }
}
