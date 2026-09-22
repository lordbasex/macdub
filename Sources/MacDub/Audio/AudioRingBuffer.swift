import Foundation
import AVFAudio

/// Keeps the last N seconds of captured (mono) audio so an assistant can ask for a snippet
/// through MCP (`get_audio_snippet`) — e.g. to double-check a dubious sentence. Never written
/// to disk unless explicitly requested; cleared when capture stops.
final class AudioRingBuffer {
    private let lock = NSLock()
    private var samples: [Float]
    private var writeIndex = 0
    private var filled = 0
    private(set) var sampleRate: Double = 48_000
    private var capacitySeconds: Double

    init(capacitySeconds: Double) {
        self.capacitySeconds = capacitySeconds
        samples = [Float](repeating: 0, count: Int(capacitySeconds * 48_000))
    }

    var isEmpty: Bool { lock.lock(); defer { lock.unlock() }; return filled == 0 }

    func clear() {
        lock.lock()
        writeIndex = 0
        filled = 0
        lock.unlock()
    }

    /// Appends the first channel of `buffer` (the capture engines deliver mono).
    func append(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        lock.lock()
        if buffer.format.sampleRate != sampleRate {
            sampleRate = buffer.format.sampleRate
            samples = [Float](repeating: 0, count: Int(capacitySeconds * sampleRate))
            writeIndex = 0
            filled = 0
        }
        let n = Int(buffer.frameLength)
        let cap = samples.count
        guard cap > 0 else { lock.unlock(); return }
        for i in 0..<n {
            samples[writeIndex] = data[i]
            writeIndex = (writeIndex + 1) % cap
        }
        filled = min(cap, filled + n)
        lock.unlock()
    }

    /// The most recent `seconds` of audio as a contiguous mono buffer at the capture rate.
    func snapshot(lastSeconds seconds: Double) -> AVAudioPCMBuffer? {
        lock.lock()
        let count = min(filled, Int(seconds * sampleRate))
        guard count > 0, let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else {
            lock.unlock()
            return nil
        }
        let cap = samples.count
        var start = (writeIndex - count) % cap
        if start < 0 { start += cap }
        let dst = out.floatChannelData![0]
        for i in 0..<count { dst[i] = samples[(start + i) % cap] }
        out.frameLength = AVAudioFrameCount(count)
        lock.unlock()
        return out
    }

    /// Writes the last `seconds` as a 16 kHz mono 16-bit WAV (small enough to hand to a model).
    func writeWAV(to url: URL, lastSeconds seconds: Double) throws {
        guard let source = snapshot(lastSeconds: seconds) else {
            throw MacDubError.captureStopped(L("No audio has been captured yet."))
        }
        let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
        guard let converter = AVAudioConverter(from: source.format, to: targetFormat) else {
            throw MacDubError.audioTapFailed("Cannot convert audio for export")
        }
        let ratio = targetFormat.sampleRate / source.format.sampleRate
        let capacity = AVAudioFrameCount(Double(source.frameLength) * ratio) + 64
        guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            throw MacDubError.audioTapFailed("Cannot allocate export buffer")
        }
        var consumed = false
        var error: NSError?
        converter.convert(to: converted, error: &error) { _, status in
            if consumed { status.pointee = .endOfStream; return nil }
            consumed = true
            status.pointee = .haveData
            return source
        }
        if let error { throw error }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: url)
        let file = try AVAudioFile(forWriting: url, settings: targetFormat.settings, commonFormat: .pcmFormatInt16, interleaved: true)
        try file.write(from: converted)
    }
}
