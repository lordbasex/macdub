import Foundation
import CoreAudio
import AudioToolbox
import AVFAudio
import Accelerate
import os

/// Alternative to `AudioCaptureManager` built on Core Audio *process taps* (macOS 14.2+).
///
/// A tap on the target's audio processes with `muteBehavior = .mutedWhenTapped` removes the
/// app's audio from the real output while we receive it. We then write it back into the
/// output ourselves, scaled by `passthroughGain` — that is what lets the user keep the original
/// voice "in the background" under the dub, documentary style. The same audio, downmixed to
/// mono, feeds the speech recognizer.
///
/// Requires the Screen & System Audio Recording permission (same TCC grant as ScreenCaptureKit).
final class ProcessTapCaptureManager {
    typealias BufferHandler = (AVAudioPCMBuffer) -> Void

    /// RMS level of the last buffer, 0…1. Called on the IO queue.
    var onLevel: ((Float) -> Void)?

    /// Target gain (0…1) for the original audio; ramped inside the IO callback.
    var passthroughGain: Float {
        get { gainLock.withLock { $0 } }
        set { gainLock.withLock { $0 = max(0, min(1, newValue)) } }
    }

    private let gainLock = OSAllocatedUnfairLock<Float>(initialState: 1)
    private var currentGain: Float = 1
    private let ioQueue = DispatchQueue(label: "com.lordbasex.MacDub.tap", qos: .userInteractive)
    private let controlQueue = DispatchQueue(label: "com.lordbasex.MacDub.tap.control")

    private var target: CaptureTarget?
    private var onBuffer: BufferHandler?
    private var processObjects: [AudioObjectID] = []
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var tapFormat: AVAudioFormat?
    private var monoFormat: AVAudioFormat?
    private var processListListener: AudioObjectPropertyListenerBlock?

    var isRunning: Bool { aggregateID != kAudioObjectUnknown }

    // MARK: Lifecycle

    func start(target: CaptureTarget, onBuffer: @escaping BufferHandler) throws {
        try controlQueue.sync {
            if isRunning { tearDown() }
            self.target = target
            self.onBuffer = onBuffer
            try setUp(target: target)
            installProcessListListener()
        }
    }

    func stop() {
        controlQueue.sync {
            removeProcessListListener()
            tearDown()
            target = nil
            onBuffer = nil
        }
    }

    // MARK: Setup / teardown (on controlQueue)

    private func setUp(target: CaptureTarget) throws {
        let description: CATapDescription
        if target.isSystem {
            // Global tap minus our own process, so the synthesized voice is neither captured nor muted.
            let me = (try? Self.ownProcessObject()).map { [$0] } ?? []
            description = CATapDescription(stereoGlobalTapButExcludeProcesses: me)
            processObjects = []
            Log.capture.info("Tapping system audio (excluding MacDub)")
        } else {
            let objects = try Self.audioProcessObjects(matching: target)
            guard !objects.isEmpty else { throw MacDubError.targetNotPlayingAudio(target.name) }
            processObjects = objects
            Log.capture.info("Tapping \(objects.count) audio process(es) of \(target.name, privacy: .public)")
            description = CATapDescription(stereoMixdownOfProcesses: objects)
        }
        description.name = "MacDub · \(target.name)"
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped

        var tap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr, tap != kAudioObjectUnknown else {
            throw MacDubError.audioTapFailed("AudioHardwareCreateProcessTap failed (\(status))")
        }
        tapID = tap

        var asbd = try Self.readProperty(tap, kAudioTapPropertyFormat, kAudioObjectPropertyScopeGlobal,
                                         as: AudioStreamBasicDescription.self)
        guard let format = AVAudioFormat(streamDescription: &asbd),
              let mono = AVAudioFormat(standardFormatWithSampleRate: asbd.mSampleRate, channels: 1) else {
            tearDown()
            throw MacDubError.audioTapFailed("Unsupported tap format")
        }
        tapFormat = format
        monoFormat = mono
        Log.capture.info("Tap format: \(format.description, privacy: .public)")

        let outputDevice = try Self.readProperty(AudioObjectID(kAudioObjectSystemObject),
                                                 kAudioHardwarePropertyDefaultOutputDevice,
                                                 kAudioObjectPropertyScopeGlobal, as: AudioDeviceID.self)
        let outputUID = try Self.readProperty(outputDevice, kAudioDevicePropertyDeviceUID,
                                              kAudioObjectPropertyScopeGlobal, as: CFString.self) as String

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "MacDub \(target.name)",
            kAudioAggregateDeviceUIDKey: "com.lordbasex.MacDub.aggregate.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        var aggregateID = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID)
        guard status == noErr, aggregateID != kAudioObjectUnknown else {
            tearDown()
            throw MacDubError.audioTapFailed("AudioHardwareCreateAggregateDevice failed (\(status))")
        }
        self.aggregateID = aggregateID

        currentGain = passthroughGain
        var procID: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, ioQueue) { [weak self] _, input, _, output, _ in
            self?.render(input: input, output: output)
        }
        guard status == noErr, let procID else {
            tearDown()
            throw MacDubError.audioTapFailed("AudioDeviceCreateIOProcIDWithBlock failed (\(status))")
        }
        ioProcID = procID

        status = AudioDeviceStart(aggregateID, procID)
        guard status == noErr else {
            tearDown()
            throw MacDubError.audioTapFailed("AudioDeviceStart failed (\(status))")
        }
        Log.capture.info("Process tap running for \(target.name, privacy: .public)")
    }

    private func tearDown() {
        if aggregateID != kAudioObjectUnknown {
            if let ioProcID {
                AudioDeviceStop(aggregateID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        ioProcID = nil
        aggregateID = kAudioObjectUnknown
        tapID = kAudioObjectUnknown
        tapFormat = nil
        monoFormat = nil
        processObjects = []
    }

    /// Browsers spin audio helper processes up and down; rebuild the tap when the matching
    /// set changes so the new process is both captured and muted.
    private func installProcessListListener() {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.controlQueue.async { self?.rebuildIfProcessesChanged() }
        }
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, controlQueue, block)
        processListListener = block
    }

    private func removeProcessListListener() {
        guard let block = processListListener else { return }
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, controlQueue, block)
        processListListener = nil
    }

    private func rebuildIfProcessesChanged() {
        guard let target, isRunning, !target.isSystem else { return } // a global tap follows new processes by itself
        let now = (try? Self.audioProcessObjects(matching: target)) ?? []
        guard !now.isEmpty, Set(now) != Set(processObjects) else { return }
        Log.capture.info("Audio processes of \(target.name, privacy: .public) changed; rebuilding tap")
        tearDown()
        do {
            try setUp(target: target)
        } catch {
            Log.capture.error("Tap rebuild failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: IO callback (real-time)

    private func render(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>) {
        let inList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outList = UnsafeMutableAudioBufferListPointer(output)

        // 1. Pass the original through at the requested gain (short ramp to avoid clicks).
        let targetGain = passthroughGain
        currentGain += (targetGain - currentGain) * 0.2
        var gain = currentGain
        for i in 0..<outList.count {
            guard let dst = outList[i].mData?.assumingMemoryBound(to: Float.self) else { continue }
            let dstCount = Int(outList[i].mDataByteSize) / MemoryLayout<Float>.size
            if i < inList.count, let src = inList[i].mData?.assumingMemoryBound(to: Float.self), gain > 0.0005 {
                let n = min(dstCount, Int(inList[i].mDataByteSize) / MemoryLayout<Float>.size)
                vDSP_vsmul(src, 1, &gain, dst, 1, vDSP_Length(n))
                if n < dstCount { vDSP_vclr(dst + n, 1, vDSP_Length(dstCount - n)) }
            } else {
                vDSP_vclr(dst, 1, vDSP_Length(dstCount))
            }
        }

        // 2. Mono copy for recognition.
        guard let onBuffer, let monoFormat, inList.count > 0,
              let src = inList[0].mData?.assumingMemoryBound(to: Float.self) else { return }
        let channels = Int(inList[0].mNumberChannels)
        guard channels > 0 else { return }
        let frames = Int(inList[0].mDataByteSize) / MemoryLayout<Float>.size / channels
        guard frames > 0, let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: AVAudioFrameCount(frames)),
              let dst = mono.floatChannelData?[0] else { return }
        mono.frameLength = AVAudioFrameCount(frames)
        if channels == 1 {
            memcpy(dst, src, frames * MemoryLayout<Float>.size)
        } else if inList.count == 1 {
            // Interleaved: average the channels of each frame.
            vDSP_vclr(dst, 1, vDSP_Length(frames))
            for c in 0..<channels {
                vDSP_vadd(dst, 1, src + c, vDSP_Stride(channels), dst, 1, vDSP_Length(frames))
            }
            var scale = 1 / Float(channels)
            vDSP_vsmul(dst, 1, &scale, dst, 1, vDSP_Length(frames))
        } else {
            memcpy(dst, src, frames * MemoryLayout<Float>.size)
        }

        if let onLevel {
            var rms: Float = 0
            vDSP_rmsqv(dst, 1, &rms, vDSP_Length(frames))
            onLevel(min(1, rms * 4))
        }
        onBuffer(mono)
    }

    // MARK: Process discovery

    /// Audio HAL process objects belonging to the target app: its own pid, child processes
    /// (Chrome/Electron helpers), or bundle ids under the app's (com.google.Chrome.helper).
    /// WebKit apps play audio from launchd-spawned XPC services, hence the explicit map.
    private static let helperBundlePrefixes: [String: [String]] = [
        "com.apple.Safari": ["com.apple.WebKit"],
        "com.apple.SafariTechnologyPreview": ["com.apple.WebKit"],
    ]

    /// The HAL process object for MacDub itself.
    static func ownProcessObject() throws -> AudioObjectID {
        var pid = ProcessInfo.processInfo.processIdentifier
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafePointer(to: &pid) { pidPtr in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                       UInt32(MemoryLayout<pid_t>.size), pidPtr, &size, &object)
        }
        guard status == noErr, object != kAudioObjectUnknown else {
            throw MacDubError.audioTapFailed("TranslatePIDToProcessObject failed (\(status))")
        }
        return object
    }

    static func audioProcessObjects(matching target: CaptureTarget) throws -> [AudioObjectID] {
        let all = try readArrayProperty(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList,
                                        as: AudioObjectID.self)
        if target.isSystem {
            let me = try? ownProcessObject()
            return all.filter { $0 != me }
        }
        let prefixes = [target.bundleIdentifier] + (helperBundlePrefixes[target.bundleIdentifier] ?? [])
        return all.filter { object in
            let pid = (try? readProperty(object, kAudioProcessPropertyPID, kAudioObjectPropertyScopeGlobal, as: pid_t.self)) ?? -1
            if pid == target.pid || isDescendant(pid, of: target.pid) { return true }
            if let bundle = try? readProperty(object, kAudioProcessPropertyBundleID, kAudioObjectPropertyScopeGlobal,
                                              as: CFString.self) as String {
                return prefixes.contains { bundle.hasPrefix($0) }
            }
            return false
        }
    }

    /// True while any of the target's audio processes is currently outputting audio.
    static func isProducingAudio(_ target: CaptureTarget) -> Bool {
        guard let objects = try? audioProcessObjects(matching: target) else { return false }
        return objects.contains { object in
            let running = (try? readProperty(object, kAudioProcessPropertyIsRunningOutput,
                                             kAudioObjectPropertyScopeGlobal, as: UInt32.self)) ?? 0
            return running != 0
        }
    }

    private static func isDescendant(_ pid: pid_t, of ancestor: pid_t) -> Bool {
        var current = pid
        for _ in 0..<6 {
            guard current > 1, let parent = parentPID(of: current) else { return false }
            if parent == ancestor { return true }
            current = parent
        }
        return false
    }

    private static func parentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }

    // MARK: Property helpers

    private static func readProperty<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                        _ scope: AudioObjectPropertyScope, as type: T.Type) throws -> T {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        let pointer = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { pointer.deallocate() }
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer)
        guard status == noErr else { throw MacDubError.audioTapFailed("Property \(selector.fourCC) failed (\(status))") }
        return pointer.pointee
    }

    private static func readArrayProperty<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                             as type: T.Type) throws -> [T] {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size)
        guard status == noErr else { throw MacDubError.audioTapFailed("Property size \(selector.fourCC) failed (\(status))") }
        let count = Int(size) / MemoryLayout<T>.stride
        var result = [T](unsafeUninitializedCapacity: count) { buffer, initialized in
            status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, buffer.baseAddress!)
            initialized = status == noErr ? count : 0
        }
        guard status == noErr else { throw MacDubError.audioTapFailed("Property \(selector.fourCC) failed (\(status))") }
        result.removeAll(where: { _ in false })
        return result
    }
}

private extension AudioObjectPropertySelector {
    var fourCC: String {
        let bytes = [UInt8(self >> 24 & 0xFF), UInt8(self >> 16 & 0xFF), UInt8(self >> 8 & 0xFF), UInt8(self & 0xFF)]
        return String(bytes: bytes, encoding: .macOSRoman) ?? "\(self)"
    }
}
