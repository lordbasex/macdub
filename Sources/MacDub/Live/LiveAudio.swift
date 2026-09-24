import Foundation
import AVFAudio
import CoreAudio

// Audio plumbing for live translation: the microphone in MacDub's capture format, a voice
// rendered into buffers, and an output device (the virtual microphone a call app listens to).

enum LiveAudio {
    /// The output device with this exact name (e.g. "BlackHole 2ch").
    static func outputDevice(named name: String) -> AudioDeviceID? {
        devices().first { deviceName($0) == name && hasStreams($0, scope: kAudioObjectPropertyScopeOutput) }
    }

    /// Whether sound currently goes to the Mac's own speakers: the microphone would then hear
    /// the translated voice of the other side and send it back to them.
    static func defaultOutputIsBuiltInSpeaker() -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else { return false }
        var transport = UInt32(0)
        address.mSelector = kAudioDevicePropertyTransportType
        size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport) == noErr else { return false }
        // Built-in covers the speakers and wired headphones on the jack; the jack reports a
        // headphone data source, the speakers do not.
        guard transport == kAudioDeviceTransportTypeBuiltIn else { return false }
        var source = UInt32(0)
        address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDataSource,
                                             mScope: kAudioObjectPropertyScopeOutput,
                                             mElement: kAudioObjectPropertyElementMain)
        size = UInt32(MemoryLayout<UInt32>.size)
        if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &source) == noErr {
            return source != 0x6864706E // 'hdpn'
        }
        return true
    }

    /// Speaks into buffers instead of the speakers (`AVSpeechSynthesizer.write`).
    static func render(_ text: String, voice: AVSpeechSynthesisVoice?) async -> [AVAudioPCMBuffer] {
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

    private static func devices() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func deviceName(_ id: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name) == noErr else { return nil }
        return name?.takeRetainedValue() as String?
    }

    private static func hasStreams(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: scope,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }
}

/// The default input device, delivered as MacDub's capture format (mono float32, 48 kHz),
/// with each buffer's peak level.
final class LiveMicrophone {
    private let engine = AVAudioEngine()
    private let onBuffer: (AVAudioPCMBuffer, Float) -> Void

    init(onBuffer: @escaping (AVAudioPCMBuffer, Float) -> Void) {
        self.onBuffer = onBuffer
    }

    func start() throws {
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        guard let converter = AVAudioConverter(from: inFormat, to: format) else {
            throw MacDubError.speechRecognizerUnavailable("microphone format \(inFormat)")
        }
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
            onBuffer(out, peak)
        }
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}

/// Plays sentences one after another on one output device.
actor LiveDeviceSpeaker {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var connected = false

    init(device: AudioDeviceID) throws {
        guard let unit = engine.outputNode.audioUnit else { throw MacDubError.speechRecognizerUnavailable("no output unit") }
        var id = device
        let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                          &id, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else { throw MacDubError.speechRecognizerUnavailable("output device (\(status))") }
        engine.attach(player)
    }

    /// Queues a sentence; `started` fires when its first buffer starts playing.
    func enqueue(_ buffers: [AVAudioPCMBuffer], started: @escaping @Sendable () -> Void) {
        guard let first = buffers.first else { return }
        if !connected {
            engine.connect(player, to: engine.mainMixerNode, format: first.format)
            try? engine.start()
            player.play()
            connected = true
        }
        player.scheduleBuffer(first, completionCallbackType: .dataConsumed) { _ in started() }
        for b in buffers.dropFirst() { player.scheduleBuffer(b, completionHandler: nil) }
    }

    func stop() {
        player.stop()
        engine.stop()
    }
}
