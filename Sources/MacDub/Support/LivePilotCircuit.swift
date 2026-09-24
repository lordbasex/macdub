import Foundation
import AVFAudio
import CoreAudio
import AppKit
import Translation
import MacDubCore

/// Pilot for live translation, outgoing side end to end (branch `live-translation-pilot`):
///
///     open -W -n build/MacDub.app --args --pilot-live --from es-MX --to en-US \
///         --voice personal|<identifier> --device "BlackHole 2ch" --seconds 60 --report /tmp/live.json
///
/// The default microphone → recognition (SpeechAnalyzer) → translation → the chosen voice →
/// the output device a call app uses as its microphone. Each sentence is timed: when the
/// microphone last heard speech before it, when it was recognized, translated, and when its
/// voice started playing.
extension LivePilot {
    static var isLiveRequested: Bool { CommandLine.arguments.contains("--pilot-live") }

    static func runLiveAndExit() -> Never {
        NSApplication.shared.setActivationPolicy(.prohibited)
        Task.detached {
            let args = CommandLine.arguments
            var report: [String: Any] = [:]
            do {
                if #available(macOS 26.0, *) {
                    report = try await runLive(args)
                } else {
                    report["error"] = "live translation pilot needs macOS 26"
                }
            } catch {
                report["error"] = error.localizedDescription
            }
            if let path = arg("--report", in: args),
               let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: path))
            }
            exit(report["error"] == nil ? 0 : 1)
        }
        RunLoop.main.run()
        exit(0)
    }

    fileprivate static func arg(_ name: String, in args: [String]) -> String? {
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    private struct LiveFailure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    @available(macOS 26.0, *)
    private static func runLive(_ args: [String]) async throws -> [String: Any] {
        let from = Locale(identifier: arg("--from", in: args) ?? "es-MX")
        let to = Locale(identifier: arg("--to", in: args) ?? "en-US")
        let seconds = Double(arg("--seconds", in: args) ?? "60") ?? 60
        guard let deviceName = arg("--device", in: args), let device = outputDevice(named: deviceName) else {
            throw LiveFailure("missing or unknown --device")
        }
        if await AVAudioApplication.requestRecordPermission() == false { throw LiveFailure("microphone not allowed") }
        if SpeechAndTranslationManager.authorizationStatus() != .authorized {
            _ = await SpeechAndTranslationManager.requestAuthorization()
        }

        let voice: AVSpeechSynthesisVoice?
        var personalVoices: [String] = []
        if arg("--voice", in: args) == "personal" {
            if VoiceSynthesisManager.personalVoiceStatus == .notDetermined { _ = await VoiceSynthesisManager.requestPersonalVoice() }
            let personal = AVSpeechSynthesisVoice.speechVoices().filter(VoiceSynthesisManager.isPersonal)
            // A Personal Voice may speak several languages; prefer the entry for the target one.
            voice = personal.first { $0.language.hasPrefix(String(to.identifier.prefix(2))) } ?? personal.first
            personalVoices = personal.map { "\($0.name) · \($0.language) · \($0.identifier)" }
        } else if let id = arg("--voice", in: args) {
            voice = AVSpeechSynthesisVoice(identifier: id)
        } else {
            voice = VoiceSynthesisManager.voices(forLanguageCode: String(to.identifier.prefix(2))).first
        }

        let session = TranslationSession(installedSource: from.language, target: to.language)
        // The first translation loads the model (~2.7 s measured): do it before anyone speaks.
        _ = try? await session.translate("Hola")
        let log = SentenceLog()
        let speaker = try DeviceSpeaker(device: device)
        let clock = Date()
        let now: @Sendable () -> Double = { Date().timeIntervalSince(clock) }

        let manager = SpeechAndTranslationManager(translator: await TranslationBridge())
        let mic = try Microphone { buffer, loud in
            if loud { log.heard(at: now()) }
            manager.append(buffer)
        }
        manager.onSegmentRecognized = { segment in
            let id = log.recognized(segment.original, at: now())
            Task {
                do {
                    let translated = try await session.translate(segment.original).targetText
                    log.translated(id, translated, at: now())
                    let buffers = try await render(text: translated, voice: voice)
                    await speaker.enqueue(buffers) { log.spoken(id, at: now()) }
                } catch {
                    log.failed(id, error.localizedDescription)
                }
            }
        }
        manager.finalizeAfterPause = Double(arg("--finalize-after", in: args) ?? "0.5") ?? 0.5
        manager.analyzerFastResults = !args.contains("--no-fast-results")
        try manager.start(sourceLocale: from, engineKind: .analyzer)
        try mic.start()
        try await Task.sleep(for: .seconds(seconds))
        mic.stop()
        try await Task.sleep(for: .seconds(4))
        manager.stop()
        try await Task.sleep(for: .seconds(3))

        return [
            "from": from.identifier, "to": to.identifier, "engine": manager.engineKind.rawValue,
            "voice": voice.map { "\($0.name) · \($0.language)" } ?? "default", "device": deviceName,
            "sentences": log.rows, "personalVoices": personalVoices,
        ]
    }

    /// `AVSpeechSynthesizer.write` into buffers (the voice goes to a device, not the speakers).
    fileprivate static func render(text: String, voice: AVSpeechSynthesisVoice?) async throws -> [AVAudioPCMBuffer] {
        let synthesizer = AVSpeechSynthesizer()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        return await withCheckedContinuation { cont in
            var list: [AVAudioPCMBuffer] = []
            var done = false
            synthesizer.write(utterance) { buffer in
                guard !done else { return }
                guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else {
                    done = true
                    withExtendedLifetime(synthesizer) { cont.resume(returning: list) }
                    return
                }
                list.append(pcm)
            }
        }
    }
}

/// Per-sentence timeline of the pilot.
private final class SentenceLog: @unchecked Sendable {
    private let lock = NSLock()
    private var lastHeard = 0.0
    private var list: [[String: Any]] = []

    func heard(at t: Double) { lock.lock(); lastHeard = t; lock.unlock() }

    func recognized(_ text: String, at t: Double) -> Int {
        lock.lock(); defer { lock.unlock() }
        list.append(["text": text, "speechEnd": lastHeard, "recognized": t])
        return list.count - 1
    }
    func translated(_ id: Int, _ text: String, at t: Double) { update(id) { $0["translation"] = text; $0["translated"] = t } }
    func spoken(_ id: Int, at t: Double) { update(id) { $0["voiceStarted"] = t } }
    func failed(_ id: Int, _ error: String) { update(id) { $0["error"] = error } }

    private func update(_ id: Int, _ change: (inout [String: Any]) -> Void) {
        lock.lock(); change(&list[id]); lock.unlock()
    }

    var rows: [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        return list.map { row in
            var r = row
            if let end = row["speechEnd"] as? Double, let started = row["voiceStarted"] as? Double {
                r["delay"] = started - end   // end of what was heard → the voice starts
            }
            return r
        }
    }
}

/// The default input device, delivered as MacDub's capture format (mono float32, 48 kHz).
private final class Microphone {
    private let engine = AVAudioEngine()
    private let onBuffer: (AVAudioPCMBuffer, Bool) -> Void

    init(onBuffer: @escaping (AVAudioPCMBuffer, Bool) -> Void) throws {
        self.onBuffer = onBuffer
    }

    func start() throws {
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        guard let converter = AVAudioConverter(from: inFormat, to: format) else { throw NSError(domain: "pilot", code: 1) }
        input.installTap(onBus: 0, bufferSize: 1024, format: inFormat) { [onBuffer] buffer, _ in
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * 48_000 / inFormat.sampleRate) + 32
            guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
            var consumed = false
            converter.convert(to: out, error: nil) { _, status in
                if consumed { status.pointee = .noDataNow; return nil }
                consumed = true; status.pointee = .haveData; return buffer
            }
            var peak: Float = 0
            if let ch = out.floatChannelData { for i in 0..<Int(out.frameLength) { peak = max(peak, abs(ch[0][i])) } }
            onBuffer(out, peak > 0.02)
        }
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}

/// Plays sentences one after another on one output device.
private actor DeviceSpeaker {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var connected = false

    init(device: AudioDeviceID) throws {
        guard let unit = engine.outputNode.audioUnit else { throw NSError(domain: "pilot", code: 2) }
        var id = device
        let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                          &id, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else { throw NSError(domain: "pilot", code: Int(status)) }
        engine.attach(player)
    }

    func enqueue(_ buffers: [AVAudioPCMBuffer], started: @escaping @Sendable () -> Void) async {
        guard let first = buffers.first else { return }
        if !connected {
            engine.connect(player, to: engine.mainMixerNode, format: first.format)
            try? engine.start()
            player.play()
            connected = true
        }
        // The first buffer's playback start ≈ when the voice starts.
        player.scheduleBuffer(first, completionCallbackType: .dataConsumed) { _ in started() }
        for b in buffers.dropFirst() { player.scheduleBuffer(b, completionHandler: nil) }
    }
}
