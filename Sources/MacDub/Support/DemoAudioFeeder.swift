import Foundation
import AVFAudio

/// Plays an audio file into a pipeline in real time, as if it came from the microphone or the
/// captured app: MacDub's capture format (mono float32, 48 kHz, 1024-frame buffers). For demos
/// and README screenshots with real recognition and translation (the `demoDub` / `demoLive`
/// commands), like the recognition benchmark does headless.
final class DemoAudioFeeder {
    private var task: Task<Void, Never>?

    /// Feeds `url` from the start; `onBuffer` gets each buffer and its peak level.
    init(url: URL, onBuffer: @escaping @Sendable (AVAudioPCMBuffer, Float) -> Void) throws {
        let file = try AVAudioFile(forReading: url)
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        guard let converter = AVAudioConverter(from: file.processingFormat, to: format) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let inRate = file.processingFormat.sampleRate
        task = Task.detached(priority: .userInitiated) {
            let clock = ContinuousClock()
            let start = clock.now
            var fed = 0.0
            while !Task.isCancelled, file.framePosition < file.length {
                let frames = AVAudioFrameCount(1024 * inRate / 48_000)
                guard let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames),
                      (try? file.read(into: input, frameCount: frames)) != nil, input.frameLength > 0,
                      let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024 + 64) else { break }
                var consumed = false
                converter.convert(to: output, error: nil) { _, status in
                    if consumed { status.pointee = .noDataNow; return nil }
                    consumed = true; status.pointee = .haveData; return input
                }
                let due = start + .seconds(fed)
                if due > clock.now { try? await Task.sleep(until: due, clock: clock) }
                var peak: Float = 0
                if let ch = output.floatChannelData { for i in 0..<Int(output.frameLength) { peak = max(peak, abs(ch[0][i])) } }
                onBuffer(output, peak)
                fed += Double(output.frameLength) / 48_000
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}
