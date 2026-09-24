import Foundation
import AVFAudio
import CoreAudio
import AppKit

// Audio plumbing for live translation: the microphone in MacDub's capture format, a voice
// rendered into buffers, and an output device (the virtual microphone a call app listens to).

enum LiveAudio {
    /// The output device with this exact name (e.g. "BlackHole 2ch").
    static func outputDevice(named name: String) -> AudioDeviceID? {
        devices().first { deviceName($0) == name && hasStreams($0, scope: kAudioObjectPropertyScopeOutput) }
    }

    struct InputDevice: Identifiable, Hashable {
        let uid: String      // stable across reconnections (AudioDeviceID is not)
        let name: String
        var id: String { uid }
    }

    /// Microphones, by name, without `excluding` (the virtual microphone: MacDub would hear itself).
    static func inputDevices(excluding excluded: String? = nil) -> [InputDevice] {
        devices().compactMap { id in
            guard hasStreams(id, scope: kAudioObjectPropertyScopeInput), let name = deviceName(id), name != excluded,
                  let uid = deviceUID(id) else { return nil }
            return InputDevice(uid: uid, name: name)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func device(uid: String) -> AudioDeviceID? {
        devices().first { deviceUID($0) == uid }
    }

    static func defaultInputName() -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else { return nil }
        return deviceName(device)
    }

    private static func deviceUID(_ id: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &uid) == noErr else { return nil }
        return uid?.takeRetainedValue() as String?
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

/// A microphone (the chosen one, or the system's default), delivered as MacDub's capture format
/// (mono float32, 48 kHz), with each buffer's peak level.
final class LiveMicrophone {
    private let engine = AVAudioEngine()
    private let deviceUID: String?
    private let onBuffer: (AVAudioPCMBuffer, Float) -> Void

    init(deviceUID: String? = nil, onBuffer: @escaping (AVAudioPCMBuffer, Float) -> Void) {
        self.deviceUID = deviceUID
        self.onBuffer = onBuffer
    }

    private var observer: NSObjectProtocol?

    func start() throws {
        try startEngine()
        // A Bluetooth headset switching to its call mode changes the input format and stops the
        // engine: start again with the new format.
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            guard let self else { return }
            Log.app.notice("Live translation: microphone configuration changed; restarting it")
            self.engine.inputNode.removeTap(onBus: 0)
            self.engine.stop()
            try? self.startEngine()
        }
    }

    private func startEngine() throws {
        let input = engine.inputNode
        // The chosen microphone rather than the system's (missing, e.g. unplugged: the default).
        if let uid = deviceUID, let device = LiveAudio.device(uid: uid), let unit = input.audioUnit {
            var id = device
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                              &id, UInt32(MemoryLayout<AudioDeviceID>.size))
            if status != noErr { Log.app.error("Live translation: cannot select the microphone (\(status))") }
        }
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
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}

/// Plays sentences one after another on one output device.
///
/// The device must stay that one: when the microphone in use is a Bluetooth headset (AirPods),
/// macOS switches it to its call mode, the audio configuration changes, and a restarted engine
/// may land on the default output — you then hear your own translated voice. So every
/// configuration change gets a new engine pointed at the device again.
actor LiveDeviceSpeaker {
    private let device: AudioDeviceID
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var observer: NSObjectProtocol?

    init(device: AudioDeviceID) throws {
        self.device = device
    }

    /// Queues a sentence; `started` fires when its first buffer starts playing.
    func enqueue(_ buffers: [AVAudioPCMBuffer], started: @escaping @Sendable () -> Void) {
        guard let first = buffers.first else { return }
        if engine?.isRunning != true { build(format: first.format) }
        guard let player else { return }
        player.scheduleBuffer(first, completionCallbackType: .dataConsumed) { _ in started() }
        for b in buffers.dropFirst() { player.scheduleBuffer(b, completionHandler: nil) }
    }

    /// A new engine pointed at the device. Re-pointing an engine that already ran can leave it
    /// unable to start again, so a configuration change gets a fresh one.
    private func build(format: AVAudioFormat) {
        tearDown()
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        guard let unit = engine.outputNode.audioUnit else { return }
        var id = device
        let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                          &id, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else {
            Log.app.error("Live translation: cannot select the call's device (\(status))")
            return
        }
        engine.connect(player, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
        } catch {
            Log.app.error("Live translation: call voice engine failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        player.play()
        self.engine = engine
        self.player = player
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            Log.app.notice("Live translation: audio configuration changed; rebuilding the call voice")
            Task { await self?.build(format: format) }
        }
    }

    private func tearDown() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        player?.stop()
        engine?.stop()
        engine = nil
        player = nil
    }

    func stop() { tearDown() }
}

/// Helps install BlackHole, the free, open-source virtual audio driver live translation uses as
/// the call's microphone (installed on its own; MacDub does not bundle it). Commands run in
/// Terminal — they ask for the administrator password — through a `.command` file, so MacDub
/// needs no Automation permission.
enum VirtualMicInstaller {
    static let blackHoleCask = "blackhole-2ch"
    static let homebrewURL = URL(string: "https://brew.sh")!
    static let blackHoleURL = URL(string: "https://existential.audio/blackhole/")!

    /// Homebrew's `brew`, where its installer puts it (Apple silicon, then Intel).
    static var brewPath: String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Installs BlackHole with Homebrew and restarts the audio service so it shows up now.
    static func installBlackHole() {
        guard let brew = brewPath else { return installHomebrewAndBlackHole() }
        run("""
        echo "MacDub: installing BlackHole (virtual microphone for live translation)…"
        "\(brew)" install --cask \(blackHoleCask) && sudo killall coreaudiod
        echo; echo "Done. Go back to MacDub."
        """)
    }

    /// Homebrew's official installer, then BlackHole.
    static func installHomebrewAndBlackHole() {
        run("""
        echo "MacDub: installing Homebrew (https://brew.sh), then BlackHole…"
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" || exit 1
        BREW=/opt/homebrew/bin/brew; [ -x "$BREW" ] || BREW=/usr/local/bin/brew
        "$BREW" install --cask \(blackHoleCask) && sudo killall coreaudiod
        echo; echo "Done. Go back to MacDub."
        """)
    }

    private static func run(_ script: String) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MacDub-install-virtual-mic.command")
        let text = "#!/bin/bash\n" + script + "\n"
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            NSWorkspace.shared.open(url)
        } catch {
            Log.app.error("Could not open the installer: \(error.localizedDescription, privacy: .public)")
        }
    }
}
