import Foundation

/// Which word of a sentence is being said at a given point of its cue.
///
/// The recognizer gives no per-word timing that survives into the transcript, so playback in
/// History spreads the cue over the words in proportion to their length: a word of 8 letters
/// gets twice the time of a word of 4. Good enough for the eye to follow the voice.
public enum Karaoke {
    /// UTF-16 range of the word at `progress` (0…1) through `text`, or nil when the text has no
    /// words. The range is what `NSRange`-based highlighting (`SpokenText`) expects.
    public static func wordRange(in text: String, progress: Double) -> NSRange? {
        let words = wordRanges(in: text)
        guard !words.isEmpty else { return nil }
        let total = words.reduce(0) { $0 + $1.length }
        guard total > 0 else { return nil }
        let target = min(1, max(0, progress)) * Double(total)
        var seen = 0.0
        for range in words {
            seen += Double(range.length)
            if target < seen { return range }
        }
        return words.last
    }

    /// The words of `text` as UTF-16 ranges, in order.
    public static func wordRanges(in text: String) -> [NSRange] {
        var ranges: [NSRange] = []
        let ns = text as NSString
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.byWords, .substringNotRequired]) { _, range, _, _ in
            ranges.append(range)
        }
        return ranges
    }
}
