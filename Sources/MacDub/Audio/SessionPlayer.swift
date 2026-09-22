import Foundation
import AVFAudio
import Accelerate
import Combine
import MacDubCore

/// Plays a recorded session back for History: transport, position and a live spectrum.
///
/// `currentTime` is published at ~12 Hz (enough for the karaoke word to move) and the spectrum
/// through a separate `SpectrumMeter` at ~30 Hz, so the transcript list does not re-render for
/// every spectrum frame — the same split as `AppState.meter`.
@MainActor
final class SessionPlayer: ObservableObject {
    /// One sentence of the session: when it is on screen and what the voice says for it.
    struct Line {
        let id = UUID()
        let cue: TranscriptExporter.Cue
        let translated: String?
    }

    /// Word the translated voice is pronouncing (index into the script), for karaoke.
    struct SpokenWord: Equatable {
        let index: Int
        let range: NSRange
    }

    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var url: URL?
    @Published private(set) var spokenWord: SpokenWord?
    let meter = SpectrumMeter(bands: 32)

    /// The translated voice, driven by the playhead: each sentence is spoken when its cue starts.
    /// Same class as the live dub, so voice, rate and catch-up behave the same.
    let voice = VoiceSynthesisManager()
    /// Speak the translation while playing (documentary / voice-only modes).
    var speakTranslation = false {
        didSet {
            guard speakTranslation != oldValue else { return }
            if speakTranslation { resyncVoice(); if isPlaying { feedVoice() } } else { voice.stop(); spokenWord = nil }
        }
    }
    /// Level of the recorded (original) audio, 0…1.
    var originalVolume: Float {
        get { node.volume }
        set { node.volume = min(1, max(0, newValue)) }
    }

    private var script: [Line] = []
    private var indexByID: [UUID: Int] = [:]
    private var nextToSpeak = 0

    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private var file: AVAudioFile?
    /// Frame the current schedule started at (seeking reschedules from here).
    private var startFrame: AVAudioFramePosition = 0
    /// Position while paused (the node reports nothing then).
    private var pausedAt: TimeInterval = 0
    private var scheduleGeneration = 0
    private var ticker: Timer?
    private var meterTicker: Timer?
    private let analyzer = SpectrumAnalyzer(bands: 32)

    init() {
        engine.attach(node)
        voice.onWordRange = { [weak self] id, range in
            MainActor.assumeIsolated {
                guard let self, let index = self.indexByID[id] else { return }
                self.spokenWord = range.map { SpokenWord(index: index, range: $0) }
            }
        }
    }

    func load(_ url: URL, script: [Line] = []) throws {
        stop()
        self.script = script
        indexByID = Dictionary(uniqueKeysWithValues: script.enumerated().map { ($1.id, $0) })
        nextToSpeak = 0
        let file = try AVAudioFile(forReading: url)
        self.file = file
        self.url = url
        duration = Double(file.length) / file.processingFormat.sampleRate
        engine.disconnectNodeOutput(node)
        engine.connect(node, to: engine.mainMixerNode, format: file.processingFormat)
        node.removeTap(onBus: 0)
        let analyzer = self.analyzer
        node.installTap(onBus: 0, bufferSize: 2048, format: file.processingFormat) { buffer, _ in
            analyzer.push(buffer)
        }
        engine.prepare()
        pausedAt = 0
        currentTime = 0
        schedule(from: 0)
    }

    func toggle() { isPlaying ? pause() : play() }

    func play() {
        guard file != nil, !isPlaying else { return }
        if currentTime >= duration - 0.05 { seek(to: 0) }
        do { try engine.start() } catch {
            Log.app.error("Playback engine failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        node.play()
        isPlaying = true
        if speakTranslation { voice.resume(); feedVoice() }
        startTickers()
    }

    func pause() {
        guard isPlaying else { return }
        pausedAt = position
        node.pause()
        voice.pause()
        isPlaying = false
        currentTime = pausedAt
        ticker?.invalidate(); ticker = nil
    }

    func seek(to seconds: TimeInterval) {
        guard let file else { return }
        let t = min(max(0, seconds), duration)
        let wasPlaying = isPlaying
        node.stop()
        isPlaying = false
        pausedAt = t
        currentTime = t
        schedule(from: AVAudioFramePosition(t * file.processingFormat.sampleRate))
        resyncVoice()
        if wasPlaying { play() }
    }

    func stop() {
        voice.stop()
        spokenWord = nil
        node.stop()
        node.removeTap(onBus: 0)
        engine.stop()
        isPlaying = false
        ticker?.invalidate(); ticker = nil
        meterTicker?.invalidate(); meterTicker = nil
        meter.bands = Array(repeating: 0, count: meter.bands.count)
        file = nil
        url = nil
        currentTime = 0
        pausedAt = 0
        duration = 0
    }

    // MARK: - Voice

    /// After a jump: forget queued sentences and continue from the one at the playhead.
    private func resyncVoice() {
        voice.stop()
        spokenWord = nil
        let t = currentTime
        nextToSpeak = script.firstIndex { $0.cue.end > t } ?? script.count
    }

    /// Speaks every sentence whose cue has started and was not spoken yet (normally one).
    private func feedVoice() {
        guard speakTranslation else { return }
        while nextToSpeak < script.count, script[nextToSpeak].cue.start <= currentTime {
            let line = script[nextToSpeak]
            nextToSpeak += 1
            if let text = line.translated { voice.speak(text, segmentID: line.id) }
        }
    }

    // MARK: -

    private var position: TimeInterval {
        guard isPlaying, let nodeTime = node.lastRenderTime, let t = node.playerTime(forNodeTime: nodeTime) else { return pausedAt }
        return min(duration, Double(startFrame + t.sampleTime) / t.sampleRate)
    }

    private func schedule(from frame: AVAudioFramePosition) {
        guard let file else { return }
        startFrame = frame
        let remaining = AVAudioFrameCount(max(0, file.length - frame))
        scheduleGeneration += 1
        let generation = scheduleGeneration
        guard remaining > 0 else { return }
        node.scheduleSegment(file, startingFrame: frame, frameCount: remaining, at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, generation == self.scheduleGeneration else { return }
                self.node.stop()
                self.isPlaying = false
                self.pausedAt = self.duration
                self.currentTime = self.duration
                self.ticker?.invalidate(); self.ticker = nil
            }
        }
    }

    private func startTickers() {
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 1.0 / 12, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isPlaying else { return }
                self.currentTime = self.position
                self.feedVoice()
            }
        }
        if meterTicker == nil {
            meterTicker = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let fresh = self.isPlaying ? self.analyzer.latest() : nil
                    let decayed = zip(self.meter.bands, fresh ?? Array(repeating: 0, count: self.meter.bands.count))
                        .map { max($1, $0 * 0.78) }
                    if decayed != self.meter.bands { self.meter.bands = decayed }
                    if !self.isPlaying, decayed.allSatisfy({ $0 < 0.01 }) {
                        self.meterTicker?.invalidate(); self.meterTicker = nil
                    }
                }
            }
        }
    }
}

/// Spectrum bands (0…1 each) for the bar display. Separate object: 30 Hz updates stay out of
/// the transcript list.
@MainActor
final class SpectrumMeter: ObservableObject {
    @Published var bands: [Float]
    init(bands: Int) { self.bands = Array(repeating: 0, count: bands) }
}

/// FFT of the last played buffer, folded into log-spaced bands. Written on the render tap
/// thread, read on the main thread.
final class SpectrumAnalyzer: @unchecked Sendable {
    private let bandCount: Int
    private let n = 2048
    private let log2n: vDSP_Length = 11
    private let fft: vDSP.FFT<DSPSplitComplex>
    private var window: [Float]
    private let lock = NSLock()
    private var bands: [Float]
    private var dirty = false

    init(bands: Int) {
        bandCount = bands
        self.bands = Array(repeating: 0, count: bands)
        fft = vDSP.FFT(log2n: log2n, radix: .radix2, ofType: DSPSplitComplex.self)!
        window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
    }

    /// Bands of the most recent buffer, or nil when nothing new arrived since the last call.
    func latest() -> [Float]? {
        lock.lock(); defer { lock.unlock() }
        guard dirty else { return nil }
        dirty = false
        return bands
    }

    func push(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData?[0], Int(buffer.frameLength) >= n else { return }
        let rate = buffer.format.sampleRate
        var samples = [Float](repeating: 0, count: n)
        vDSP_vmul(data, 1, window, 1, &samples, 1, vDSP_Length(n))
        let half = n / 2
        var real = [Float](repeating: 0, count: half)
        var imag = [Float](repeating: 0, count: half)
        var magnitudes = [Float](repeating: 0, count: half)
        real.withUnsafeMutableBufferPointer { r in
            imag.withUnsafeMutableBufferPointer { i in
                var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                samples.withUnsafeBufferPointer { s in
                    s.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { complex in
                        vDSP_ctoz(complex, 2, &split, 1, vDSP_Length(half))
                    }
                }
                fft.forward(input: split, output: &split)
                vDSP_zvmags(&split, 1, &magnitudes, 1, vDSP_Length(half))
            }
        }
        // Log-spaced bands from 80 Hz to 12 kHz (speech lives well inside).
        let fMin = 80.0, fMax = min(12_000.0, rate / 2)
        let binWidth = rate / Double(n)
        let scale = 1 / Float(half)
        var out = [Float](repeating: 0, count: bandCount)
        for b in 0..<bandCount {
            let lo = fMin * pow(fMax / fMin, Double(b) / Double(bandCount))
            let hi = fMin * pow(fMax / fMin, Double(b + 1) / Double(bandCount))
            let loBin = max(1, Int(lo / binWidth))
            let hiBin = max(loBin + 1, min(half, Int(hi / binWidth)))
            var peak: Float = 0
            for k in loBin..<hiBin { peak = max(peak, magnitudes[k]) }
            let amplitude = sqrt(peak) * scale
            let db = 20 * log10(max(amplitude, 1e-7))
            out[b] = min(1, max(0, (db + 66) / 60))
        }
        lock.lock()
        bands = out
        dirty = true
        lock.unlock()
    }
}
