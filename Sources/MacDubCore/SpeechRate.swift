import Foundation

/// Speech-rate policy for the dubbing voice.
public enum SpeechRate {
    /// Rate for a new utterance given how many are already queued: +`boost` per queued sentence,
    /// capped at `maxFactor` × base and at `maximum` (the synthesizer's ceiling, 1.0 for AVFAudio).
    public static func catchUp(base: Float, backlog: Int, boost: Float, maxFactor: Float, maximum: Float = 1) -> Float {
        let factor = min(1 + boost * Float(max(0, backlog)), maxFactor)
        return min(base * factor, maximum)
    }
}
