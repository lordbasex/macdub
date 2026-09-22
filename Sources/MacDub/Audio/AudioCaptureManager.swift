import Foundation
import AppKit
import ScreenCaptureKit
import AVFAudio
import CoreMedia

/// A running application whose audio can be captured.
struct CaptureTarget: Identifiable, Hashable {
    let pid: pid_t
    let bundleIdentifier: String
    let name: String

    var id: String { "\(bundleIdentifier)#\(pid)" }

    /// Pseudo-target: every app's audio (except MacDub's own voice).
    static let systemBundleIdentifier = "system"
    static var system: CaptureTarget { CaptureTarget(pid: -1, bundleIdentifier: systemBundleIdentifier, name: L("Entire system (all apps)")) }
    var isSystem: Bool { bundleIdentifier == Self.systemBundleIdentifier }
}

/// Stage 1 of the pipeline: per-application system audio capture via ScreenCaptureKit.
///
/// The stream is configured audio-only (a 2×2 px video frame once per second is the
/// cheapest configuration SCStream accepts) and scoped to a single `SCRunningApplication`,
/// so no other app — and never the microphone — is captured. Our own process is excluded
/// explicitly so the synthesized voice is not fed back into the recognizer.
final class AudioCaptureManager: NSObject {
    typealias BufferHandler = (AVAudioPCMBuffer) -> Void

    /// Called on an arbitrary queue when the stream stops on its own (target quit, permission revoked…).
    var onStreamStopped: ((Error) -> Void)?
    /// RMS level of the last buffer, 0…1. Called on the capture queue.
    var onLevel: ((Float) -> Void)?

    private let sampleQueue = DispatchQueue(label: "com.lordbasex.MacDub.capture", qos: .userInitiated)
    private var stream: SCStream?
    private var onBuffer: BufferHandler?

    // MARK: Discovery

    /// Running applications that ScreenCaptureKit can attach to, excluding ourselves and the
    /// background agents macOS runs (only apps with a Dock presence are offered).
    static func availableTargets() async throws -> [CaptureTarget] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let me = Bundle.main.bundleIdentifier
        return content.applications
            .filter { !$0.bundleIdentifier.isEmpty && $0.bundleIdentifier != me }
            .filter { NSRunningApplication(processIdentifier: $0.processID)?.activationPolicy == .regular }
            .map {
                CaptureTarget(
                    pid: $0.processID,
                    bundleIdentifier: $0.bundleIdentifier,
                    name: $0.applicationName.isEmpty ? $0.bundleIdentifier : $0.applicationName
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: Lifecycle

    var isRunning: Bool { stream != nil }

    func start(target: CaptureTarget, sampleRate: Int = 48_000, onBuffer: @escaping BufferHandler) async throws {
        if stream != nil { await stop() }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else {
            throw MacDubError.noDisplay
        }

        let filter: SCContentFilter
        if target.isSystem {
            // Everything except ourselves (our voice is also excluded by excludesCurrentProcessAudio).
            let me = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
            filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])
        } else {
            guard let app = content.applications.first(where: { $0.processID == target.pid }) else {
                throw MacDubError.targetAppNotRunning(target.name)
            }
            // Including only `app` restricts both video and audio to that application.
            filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])
        }

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = sampleRate
        config.channelCount = 1
        // We never add a `.screen` output, but the stream still wants a video config; make it trivial.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.showsCursor = false
        config.queueDepth = 6

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)

        self.onBuffer = onBuffer
        try await stream.startCapture()
        self.stream = stream
        Log.capture.info("Capturing audio from \(target.name, privacy: .public) (pid \(target.pid))")
    }

    func stop() async {
        guard let stream else { return }
        self.stream = nil
        onBuffer = nil
        do {
            try await stream.stopCapture()
        } catch {
            // Already stopped (e.g. the target app quit). Nothing to do.
            Log.capture.debug("stopCapture: \(error.localizedDescription, privacy: .public)")
        }
        Log.capture.info("Capture stopped")
    }
}

// MARK: - SCStreamOutput / SCStreamDelegate

extension AudioCaptureManager: SCStreamOutput, SCStreamDelegate {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, sampleBuffer.numSamples > 0, let onBuffer else { return }
        guard let pcm = Self.copyToPCMBuffer(sampleBuffer) else { return }
        if let onLevel { onLevel(Self.rms(of: pcm)) }
        onBuffer(pcm)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.capture.error("Stream stopped: \(error.localizedDescription, privacy: .public)")
        self.stream = nil
        onBuffer = nil
        onStreamStopped?(error)
    }

    /// Copies the sample buffer's audio into an owned `AVAudioPCMBuffer`. The CMSampleBuffer's
    /// memory is only valid for the duration of the callback, and the speech recognizer keeps
    /// buffers around, so a copy is mandatory.
    private static func copyToPCMBuffer(_ sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard var asbd = sampleBuffer.formatDescription?.audioStreamBasicDescription,
              let format = AVAudioFormat(streamDescription: &asbd) else { return nil }
        let frameCount = AVAudioFrameCount(sampleBuffer.numSamples)
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return nil }
        out.frameLength = frameCount

        do {
            try sampleBuffer.withAudioBufferList { src, _ in
                let dst = UnsafeMutableAudioBufferListPointer(out.mutableAudioBufferList)
                for i in 0..<min(src.count, dst.count) {
                    guard let s = src[i].mData, let d = dst[i].mData else { continue }
                    memcpy(d, s, Int(min(src[i].mDataByteSize, dst[i].mDataByteSize)))
                }
            }
        } catch {
            return nil
        }
        return out
    }

    private static func rms(of buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        let n = Int(buffer.frameLength)
        var sum: Float = 0
        let ch = data[0]
        for i in 0..<n { sum += ch[i] * ch[i] }
        return min(1, (sum / Float(n)).squareRoot() * 4) // ×4 so normal speech reads mid-scale
    }
}
