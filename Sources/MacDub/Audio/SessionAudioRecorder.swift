import Foundation
import AVFAudio
import MacDubCore

/// Records the captured (original) audio of a session to `~/.macdub/audio/<id>.m4a` so History
/// can play it back under the transcript and export it next to an .srt.
///
/// Timing contract: audio position 0 is `sessionStart`, the same origin the transcript cues
/// use. Capture starts a little after that, and a session can be stopped and resumed (Stop,
/// then Start again without clearing), so on every `begin` the first buffer is preceded by as
/// much silence as the wall clock says is missing. That keeps `.srt` cues and the audio aligned
/// without per-buffer timestamps.
///
/// The file is AAC (small, native, VLC-friendly). AAC files cannot be appended to once closed,
/// so a resume re-encodes the existing take into a new file first — the sessions are short and
/// mono, that takes well under a second.
final class SessionAudioRecorder {
    private let queue = DispatchQueue(label: "com.lordbasex.MacDub.recorder", qos: .utility)
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?
    /// Where the finished take lives.
    private var url: URL?
    /// Where the open file writes: `url`, or a `.part` file while a resumed take is being rebuilt.
    private var writingURL: URL?
    private var sessionStart: Date?
    private var framesWritten: AVAudioFramePosition = 0
    private var padBeforeNextBuffer = false
    private let lock = NSLock()
    private var _active = false

    /// True between `begin` and `finish`; checked on the audio thread before enqueuing work.
    var isActive: Bool { lock.lock(); defer { lock.unlock() }; return _active }
    private func setActive(_ v: Bool) { lock.lock(); _active = v; lock.unlock() }

    private static let bitRate = 48_000

    /// Starts (or resumes) recording session audio into `url`. `sessionStart` is audio time 0.
    func begin(url: URL, sessionStart: Date) {
        setActive(true)
        queue.async { [self] in
            let resuming = self.url == url && self.sessionStart != nil && FileManager.default.fileExists(atPath: url.path)
            self.url = url
            self.sessionStart = sessionStart
            file = nil
            converter = nil
            converterInputFormat = nil
            padBeforeNextBuffer = true
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                if resuming {
                    try reopenForAppend(url)
                } else {
                    framesWritten = 0
                    writingURL = url
                    try? FileManager.default.removeItem(at: url)
                }
            } catch {
                Log.capture.error("Session recorder could not start: \(error.localizedDescription, privacy: .public)")
                setActive(false)
            }
        }
    }

    /// Enqueues a captured mono buffer. Safe to call from the audio thread: buffers delivered by
    /// the capture engines are fresh allocations, so they are just retained here, not copied.
    func append(_ buffer: AVAudioPCMBuffer) {
        guard isActive, buffer.frameLength > 0 else { return }
        queue.async { [self] in
            do { try write(buffer) } catch {
                Log.capture.error("Session recorder write failed: \(error.localizedDescription, privacy: .public)")
                setActive(false)
            }
        }
    }

    /// Closes the take. `completion` gets the file URL when something was recorded, else nil.
    func finish(completion: @escaping (URL?) -> Void) {
        setActive(false)
        queue.async { [self] in
            file?.close()
            file = nil
            converter = nil
            if let writingURL, let url, writingURL != url {
                _ = try? FileManager.default.replaceItemAt(url, withItemAt: writingURL)
                try? FileManager.default.removeItem(at: writingURL)
            }
            let result = (framesWritten > 0 ? url : nil)
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Forgets the current take (the next `begin` starts from zero). Does not delete the file.
    func reset() {
        setActive(false)
        queue.async { [self] in
            file?.close()
            file = nil
            url = nil
            writingURL = nil
            sessionStart = nil
            framesWritten = 0
        }
    }

    /// Throws the take away: what was written since the last `begin` is deleted (a `.part`
    /// of a resumed session always; the finished take at `url` only when nothing refers to it,
    /// i.e. when no session record was archived with it). Then forgets everything like `reset`.
    func discard(keepFinishedTake: Bool) {
        setActive(false)
        queue.async { [self] in
            file?.close()
            file = nil
            if let writingURL, writingURL != url { try? FileManager.default.removeItem(at: writingURL) }
            if !keepFinishedTake, let url { try? FileManager.default.removeItem(at: url) }
            url = nil
            writingURL = nil
            sessionStart = nil
            framesWritten = 0
        }
    }

    // MARK: - Queue-only

    private func fileSettings(sampleRate: Double) -> [String: Any] {
        [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate,
         AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: Self.bitRate]
    }

    private func openFile(at url: URL, sampleRate: Double) throws -> AVAudioFile {
        try AVAudioFile(forWriting: url, settings: fileSettings(sampleRate: sampleRate),
                        commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    /// Re-encodes the existing take into a `.part` file that then keeps growing.
    private func reopenForAppend(_ url: URL) throws {
        let old = try AVAudioFile(forReading: url)
        let part = url.deletingPathExtension().appendingPathExtension("part.m4a")
        try? FileManager.default.removeItem(at: part)
        let new = try openFile(at: part, sampleRate: old.processingFormat.sampleRate)
        let chunk: AVAudioFrameCount = 32_768
        guard let buffer = AVAudioPCMBuffer(pcmFormat: old.processingFormat, frameCapacity: chunk) else {
            throw MacDubError.audioTapFailed("Cannot allocate buffer to resume recording")
        }
        while old.framePosition < old.length {
            try old.read(into: buffer, frameCount: chunk)
            if buffer.frameLength == 0 { break }
            try new.write(from: buffer)
        }
        framesWritten = new.length
        file = new
        writingURL = part
    }

    private func write(_ buffer: AVAudioPCMBuffer) throws {
        let rate = buffer.format.sampleRate
        if file == nil {
            guard let writingURL else { return }
            file = try openFile(at: writingURL, sampleRate: rate)
        }
        guard let file else { return }
        let fileRate = file.processingFormat.sampleRate

        if padBeforeNextBuffer {
            padBeforeNextBuffer = false
            // Wall time now ≈ end of this buffer. Whatever is missing before it is silence.
            if let sessionStart {
                let expectedEnd = Double(framesWritten) / fileRate + Double(buffer.frameLength) / rate
                let gap = Date().timeIntervalSince(sessionStart) - expectedEnd
                if gap > 0.1 { try writeSilence(seconds: gap, to: file) }
            }
        }

        if buffer.format == file.processingFormat {
            try file.write(from: buffer)
            framesWritten = file.length
            return
        }
        // Different rate/layout (ScreenCaptureKit stream, device change): convert.
        if converter == nil || converterInputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: file.processingFormat)
            converterInputFormat = buffer.format
        }
        guard let converter else { return }
        let ratio = fileRate / rate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: capacity) else { return }
        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        if let error { throw error }
        if out.frameLength > 0 {
            try file.write(from: out)
            framesWritten = file.length
        }
    }

    private func writeSilence(seconds: TimeInterval, to file: AVAudioFile) throws {
        // Capped: a session resumed hours later gets 10 minutes of silence, not hours of it.
        let total = AVAudioFrameCount(min(seconds, 600) * file.processingFormat.sampleRate)
        let chunk: AVAudioFrameCount = 16_384
        guard total > 0, let silence = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk) else { return }
        var remaining = total
        while remaining > 0 {
            silence.frameLength = min(chunk, remaining)
            try file.write(from: silence)
            remaining -= silence.frameLength
        }
        framesWritten = file.length
    }
}
