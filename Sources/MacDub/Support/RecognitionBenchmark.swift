import Foundation
import AppKit
import AVFAudio
import Speech
import MacDubCore

/// Headless benchmark of the recognition pipeline, for comparing engines on the same audio:
///
///     open -W -n build/MacDub.app --args --benchmark-recognition talk.wav \
///         --engine analyzer --locale en-US --out result.json [--speed 1] [--seconds 600]
///
/// The file is converted to what the capture engines deliver (mono float32, 48 kHz, 1024-frame
/// buffers) and fed to the real `SpeechAndTranslationManager` at `speed`× real time, so run
/// rotation, silence cuts and segmentation behave as in a dubbing session. Every emitted segment
/// is written with the audio time it came out at; `scripts/benchmark/compare.py` scores the
/// results against a reference. Launch through `open` so the app, not the terminal, is the
/// process asking for Speech Recognition permission.
enum RecognitionBenchmark {
    static var isRequested: Bool { CommandLine.arguments.contains("--benchmark-recognition") }

    /// Runs the benchmark and exits the process.
    static func runAndExit() -> Never {
        // LaunchServices gives every `open`ed app a Dock icon; a headless run shouldn't have one.
        NSApplication.shared.setActivationPolicy(.prohibited)
        Task.detached {
            let code: Int32
            do {
                try await run(arguments: CommandLine.arguments)
                code = 0
            } catch {
                FileHandle.standardError.write(Data("benchmark: \(error.localizedDescription)\n".utf8))
                // Launched through `open`, stderr goes nowhere: leave the reason where --out points.
                let args = CommandLine.arguments
                if let i = args.firstIndex(of: "--out"), i + 1 < args.count,
                   let data = try? JSONSerialization.data(withJSONObject: ["error": error.localizedDescription]) {
                    try? data.write(to: URL(fileURLWithPath: args[i + 1]))
                }
                code = 1
            }
            exit(code)
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

    private static func run(arguments args: [String]) async throws {
        guard let path = value("--benchmark-recognition", in: args) else { throw Failure("missing audio file") }
        guard let out = value("--out", in: args) else { throw Failure("missing --out") }
        let requested = RecognitionEngineKind(rawValue: value("--engine", in: args) ?? "auto") ?? .auto
        let locale = Locale(identifier: value("--locale", in: args) ?? "en-US")
        let speed = Double(value("--speed", in: args) ?? "1") ?? 1
        let limit = Double(value("--seconds", in: args) ?? "") ?? .infinity

        if SFSpeechRecognizer.authorizationStatus() != .authorized {
            let status = await SpeechAndTranslationManager.requestAuthorization()
            guard status == .authorized else { throw Failure("Speech Recognition not authorized (\(status.rawValue))") }
        }

        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        guard let converter = AVAudioConverter(from: file.processingFormat, to: format) else { throw Failure("unsupported audio format") }
        let fileSeconds = Double(file.length) / file.processingFormat.sampleRate
        let totalSeconds = min(fileSeconds, limit)

        let recorder = Recorder()
        let manager = SpeechAndTranslationManager(translator: await TranslationBridge())
        manager.onSegmentRecognized = { segment in recorder.segment(segment.original) }
        manager.onPartial = { text in recorder.partial(text) }
        manager.onEngineChanged = { kind in recorder.event("engine changed to \(kind.rawValue)") }
        manager.onFatalError = { error in recorder.event("fatal: \(error.localizedDescription)") }
        if args.contains("--log-updates") {
            manager.onRawTranscript = { text, isFinal in recorder.update(text, isFinal: isFinal) }
            #if compiler(>=6.2)
            if #available(macOS 26.0, *) {
                SpeechAnalyzerEngine.rawResultHook = { text, isFinal, range in
                    recorder.update("[raw \(range)] " + text, isFinal: isFinal)
                }
            }
            #endif
        }

        // --analyzer-volatile: segment SpeechAnalyzer's volatile results too (the older behaviour).
        manager.analyzerFinalsOnly = !args.contains("--analyzer-volatile")
        let process = ProcessSampler()
        let clock = ContinuousClock()
        let started = clock.now
        var fed = 0.0
        /// Written every minute too, so a run cut short (killed, permission revoked) keeps its data.
        func write(complete: Bool) throws {
            let result: [String: Any] = [
                "file": path, "engine": manager.engineKind.rawValue, "requestedEngine": requested.rawValue,
                "analyzerFinalsOnly": manager.analyzerFinalsOnly,
                "locale": locale.identifier, "speed": speed, "audioSeconds": fed,
                "wallSeconds": (clock.now - started).seconds, "complete": complete,
                "chip": SystemInfo.chip, "macOS": SystemInfo.macOSVersion, "arch": SystemInfo.architecture,
                "segments": recorder.segments, "events": recorder.events, "samples": recorder.samples,
                "partials": recorder.partialCount, "updates": recorder.updates,
            ]
            let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: out), options: .atomic)
        }
        try manager.start(sourceLocale: locale, engineKind: requested)
        recorder.event("started \(manager.engineKind.rawValue)")
        recorder.audioTime = { (clock.now - started).seconds * speed }

        // Feed in real time (scaled by speed): wait until each buffer's audio time has come.
        let chunk: AVAudioFrameCount = 1024
        var nextSample = clock.now
        var nextCheckpoint = clock.now + .seconds(60)
        // A failure while feeding is recorded, and what was measured up to then is still written.
        do {
            while fed < totalSeconds {
                guard let buffer = try read(file, frames: AVAudioFrameCount(Double(chunk) * file.processingFormat.sampleRate / 48_000),
                                            converter: converter, to: format), buffer.frameLength > 0 else { break }
                let due = started + .seconds(fed / speed)
                if due > clock.now { try await Task.sleep(until: due, clock: clock) }
                manager.append(buffer)
                fed += Double(buffer.frameLength) / format.sampleRate
                if clock.now >= nextSample {
                    recorder.sample(process.sample(), at: fed)
                    nextSample = clock.now + .seconds(5)
                }
                if clock.now >= nextCheckpoint {
                    try? write(complete: false)
                    nextCheckpoint = clock.now + .seconds(60)
                }
            }
        } catch {
            recorder.event("feed error: \(error.localizedDescription)")
        }
        // Give the engine time to deliver the tail, as silence would in a session.
        try? await Task.sleep(for: .seconds(4 / max(speed, 1)))
        manager.stop()
        recorder.event("stopped")

        try write(complete: true)
    }

    private static func read(_ file: AVAudioFile, frames: AVAudioFrameCount, converter: AVAudioConverter, to format: AVAudioFormat) throws -> AVAudioPCMBuffer? {
        // AVAudioFile.read throws at the end of the file instead of returning no frames.
        guard file.framePosition < file.length,
              let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else { return nil }
        try file.read(into: input, frameCount: frames)
        if input.frameLength == 0 { return nil }
        let capacity = AVAudioFrameCount(Double(input.frameLength) * format.sampleRate / file.processingFormat.sampleRate) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return input
        }
        if let error { throw error }
        return output
    }

    /// Thread-safe log of what the pipeline produced, stamped with audio time.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        var audioTime: () -> Double = { 0 }
        private(set) var segments: [[String: Any]] = []
        private(set) var events: [[String: Any]] = []
        private(set) var samples: [[String: Any]] = []
        private(set) var partialCount = 0

        func segment(_ text: String) { append(&segments, ["t": audioTime(), "text": text]) }
        func event(_ text: String) { append(&events, ["t": audioTime(), "event": text]) }
        private(set) var updates: [[String: Any]] = []
        func update(_ text: String, isFinal: Bool) { append(&updates, ["t": audioTime(), "text": text, "final": isFinal]) }
        func partial(_ text: String) { lock.lock(); if !text.isEmpty { partialCount += 1 }; lock.unlock() }
        func sample(_ s: ProcessSampler.Sample, at t: Double) {
            append(&samples, ["t": t, "cpuPercent": s.cpuPercent, "residentMB": s.residentMB, "footprintMB": s.footprintMB])
        }
        private func append(_ list: inout [[String: Any]], _ item: [String: Any]) {
            lock.lock(); list.append(item); lock.unlock()
        }
    }
}

/// CPU (since the previous sample) and memory of this process.
final class ProcessSampler {
    struct Sample { let cpuPercent: Double; let residentMB: Double; let footprintMB: Double }

    private var lastCPU = ProcessSampler.cpuSeconds()
    private var lastWall = Date()

    func sample() -> Sample {
        let cpu = Self.cpuSeconds(), now = Date()
        let percent = (cpu - lastCPU) / max(now.timeIntervalSince(lastWall), 0.001) * 100
        lastCPU = cpu; lastWall = now
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        let mb = { (bytes: UInt64) in Double(bytes) / 1_048_576 }
        return Sample(cpuPercent: percent,
                      residentMB: kr == KERN_SUCCESS ? mb(info.resident_size) : 0,
                      footprintMB: kr == KERN_SUCCESS ? mb(info.phys_footprint) : 0)
    }

    private static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let t = { (tv: timeval) in Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000 }
        return t(usage.ru_utime) + t(usage.ru_stime)
    }
}

private extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
