import Foundation
import AppKit
import AVFAudio
import CoreAudio

/// Pilot for live translation (branch `live-translation-pilot`): the pieces the outgoing side
/// needs, checked headless before any UI.
///
///     open -W -n build/MacDub.app --args --pilot-tts "Hola, ¿cómo estás?" \
///         --voice personal|<identifier> --out /tmp/tts.caf [--device "BlackHole 2ch"] --report /tmp/r.json
///
/// Speaks `text` into buffers (`AVSpeechSynthesizer.write`) instead of the speakers — what a
/// virtual microphone needs — writes them to `--out`, and with `--device` also plays them on
/// that output device. The report says which voice was used, how much audio came out and how
/// long the first buffer took.
enum LivePilot {
    static var isRequested: Bool { CommandLine.arguments.contains("--pilot-tts") }

    static func runAndExit() -> Never {
        NSApplication.shared.setActivationPolicy(.prohibited)
        Task.detached {
            let args = CommandLine.arguments
            var report: [String: Any] = [:]
            do {
                report = try await run(args)
            } catch {
                report["error"] = error.localizedDescription
            }
            if let path = value("--report", in: args),
               let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: path))
            }
            exit(report["error"] == nil ? 0 : 1)
        }
        RunLoop.main.run()
        exit(0)
    }

    private struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    private static func value(_ name: String, in args: [String]) -> String? {
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    private static func run(_ args: [String]) async throws -> [String: Any] {
        guard let text = value("--pilot-tts", in: args) else { throw Failure("missing text") }
        guard let out = value("--out", in: args) else { throw Failure("missing --out") }
        var report: [String: Any] = ["personalVoiceStatus": VoiceSynthesisManager.personalVoiceStatus.rawValue]

        let voice: AVSpeechSynthesisVoice?
        switch value("--voice", in: args) {
        case "personal":
            if VoiceSynthesisManager.personalVoiceStatus == .notDetermined {
                _ = await VoiceSynthesisManager.requestPersonalVoice()
            }
            voice = AVSpeechSynthesisVoice.speechVoices().first(where: VoiceSynthesisManager.isPersonal)
            if voice == nil {
                throw Failure("no Personal Voice visible to MacDub (authorization \(VoiceSynthesisManager.personalVoiceStatus.rawValue), \(AVSpeechSynthesisVoice.speechVoices().count) voices)")
            }
        case let id?:
            voice = AVSpeechSynthesisVoice(identifier: id)
        case nil:
            voice = AVSpeechSynthesisVoice(language: "es-MX")
        }
        report["voice"] = voice.map { "\($0.name) · \($0.language) · \($0.identifier)" } ?? "default"

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        let buffers = try await render(utterance)
        report["buffers"] = buffers.list.count
        report["firstBufferSeconds"] = buffers.firstAfter
        guard let first = buffers.list.first else { throw Failure("the synthesizer produced no audio") }
        let format = first.format
        report["format"] = "\(format.sampleRate) Hz · \(format.channelCount) ch · \(format.commonFormat.rawValue)"
        let frames = buffers.list.reduce(0) { $0 + Int($1.frameLength) }
        report["audioSeconds"] = Double(frames) / format.sampleRate
        var peak: Float = 0
        for b in buffers.list {
            if let ch = b.floatChannelData { for i in 0..<Int(b.frameLength) { peak = max(peak, abs(ch[0][i])) } }
        }
        report["peak"] = peak

        let file = try AVAudioFile(forWriting: URL(fileURLWithPath: out), settings: format.settings,
                                   commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        for b in buffers.list { try file.write(from: b) }

        if let deviceName = value("--device", in: args) {
            guard let device = outputDevice(named: deviceName) else { throw Failure("no output device named \(deviceName)") }
            // --loopback <file>: record the same device's input meanwhile — what a call app
            // choosing it as its microphone would get.
            var recorder: LoopbackRecorder?
            if let recording = value("--loopback", in: args) {
                recorder = try LoopbackRecorder(device: device, to: URL(fileURLWithPath: recording))
                try await Task.sleep(for: .milliseconds(300))
            }
            let started = Date()
            if let count = value("--via-speaker", in: args).flatMap(Int.init) {
                // The live translation speaker, several sentences in a row (it once played only
                // the first).
                let speaker = try LiveDeviceSpeaker(device: device)
                let starts = StartLog()
                for i in 0..<count {
                    await speaker.enqueue(buffers.list) { starts.add(i) }
                    try await Task.sleep(for: .seconds(Double(frameCount(buffers.list)) / 48_000 + 1))
                }
                report["sentencesStarted"] = starts.count
                await speaker.stop()
            } else {
                try await play(buffers.list, on: device)
            }
            report["playedOn"] = deviceName
            if let recorder {
                try await Task.sleep(for: .milliseconds(500))
                let heard = recorder.stop(since: started)
                report["loopbackPeak"] = heard.peak
                report["loopbackSeconds"] = heard.seconds
                report["loopbackFirstSoundAfter"] = heard.firstSoundAfter
            }
        }
        return report
    }

    /// `write` calls back with buffers and finally one of zero frames.
    private static func render(_ utterance: AVSpeechUtterance) async throws -> (list: [AVAudioPCMBuffer], firstAfter: Double) {
        let synthesizer = AVSpeechSynthesizer()
        let start = Date()
        return await withCheckedContinuation { cont in
            var list: [AVAudioPCMBuffer] = []
            var firstAfter = -1.0
            var done = false
            synthesizer.write(utterance) { buffer in
                guard !done else { return }
                guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else {
                    done = true
                    withExtendedLifetime(synthesizer) { cont.resume(returning: (list, firstAfter)) }
                    return
                }
                if firstAfter < 0 { firstAfter = Date().timeIntervalSince(start) }
                list.append(pcm)
            }
        }
    }

    static func outputDevice(named name: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return nil }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return nil }
        for id in ids {
            var nameAddress = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                                         mScope: kAudioObjectPropertyScopeGlobal,
                                                         mElement: kAudioObjectPropertyElementMain)
            var cfName: Unmanaged<CFString>?
            var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(id, &nameAddress, 0, nil, &nameSize, &cfName) == noErr,
                  let deviceName = cfName?.takeRetainedValue() as String? else { continue }
            if deviceName == name { return id }
        }
        return nil
    }

    /// Plays on a given device rather than the default output: an engine whose output unit is
    /// pointed at it.
    private static func play(_ buffers: [AVAudioPCMBuffer], on device: AudioDeviceID) async throws {
        let engine = AVAudioEngine()
        guard let unit = engine.outputNode.audioUnit else { throw Failure("no output unit") }
        var id = device
        let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                          &id, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else { throw Failure("could not select the device (\(status))") }
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: buffers[0].format)
        try engine.start()
        player.play()
        for (i, b) in buffers.enumerated() {
            if i == buffers.count - 1 {
                await player.scheduleBuffer(b, completionCallbackType: .dataPlayedBack)
            } else {
                player.scheduleBuffer(b, completionHandler: nil)
            }
        }
        engine.stop()
    }

    private static func frameCount(_ list: [AVAudioPCMBuffer]) -> Int { list.reduce(0) { $0 + Int($1.frameLength) } }

    private final class StartLog: @unchecked Sendable {
        private let lock = NSLock()
        private var seen = Set<Int>()
        func add(_ i: Int) { lock.lock(); seen.insert(i); lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return seen.count }
    }

    /// Records a device's input into a file and measures what arrived.
    final class LoopbackRecorder {
        private let engine = AVAudioEngine()
        private let file: AVAudioFile
        private let lock = NSLock()
        private var peak: Float = 0
        private var frames = 0
        private var firstSound: Date?

        init(device: AudioDeviceID, to url: URL) throws {
            guard let unit = engine.inputNode.audioUnit else { throw Failure("no input unit") }
            var id = device
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                              &id, UInt32(MemoryLayout<AudioDeviceID>.size))
            guard status == noErr else { throw Failure("could not select the input device (\(status))") }
            let format = engine.inputNode.outputFormat(forBus: 0)
            file = try AVAudioFile(forWriting: url, settings: format.settings)
            engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                guard let self else { return }
                try? self.file.write(from: buffer)
                var p: Float = 0
                if let ch = buffer.floatChannelData { for i in 0..<Int(buffer.frameLength) { p = max(p, abs(ch[0][i])) } }
                self.lock.lock()
                self.frames += Int(buffer.frameLength)
                self.peak = max(self.peak, p)
                if p > 0.01, self.firstSound == nil { self.firstSound = Date() }
                self.lock.unlock()
            }
            try engine.start()
        }

        func stop(since start: Date) -> (peak: Float, seconds: Double, firstSoundAfter: Double) {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            lock.lock(); defer { lock.unlock() }
            let rate = engine.inputNode.outputFormat(forBus: 0).sampleRate
            return (peak, Double(frames) / max(rate, 1), firstSound.map { $0.timeIntervalSince(start) } ?? -1)
        }
    }
}
