import Foundation

/// Cuts a continuously revised transcript into sentences/chunks worth translating.
///
/// Speech recognizers stream *partial* transcripts that keep changing. The segmenter keeps a
/// character offset (`committed`) into the current transcript and emits:
/// - every sentence as soon as a terminator (`.?!`) appears after it;
/// - a clause (up to the last `,;:`) once the pending text exceeds `clauseSplitCharacters`;
/// - up to the last space *before* `maxSegmentCharacters` once the pending text exceeds it;
/// - up to the second-to-last word when text has been pending for `maxPendingDuration`
///   (talkers who never pause and get no punctuation from the model);
/// - everything pending on `flush()` (silence, run rotation, stop).
///
/// Recognizers also revise text *before* the committed offset (inserting or rewording earlier
/// words). The segmenter remembers the committed text and re-anchors the offset on the tail of
/// it, so a revision upstream never shifts what is pending.
///
/// SFSpeechRecognizer may also *restart* its transcript within the same task after a pause
/// ("…created dreams and was upon the scent" → "I"). The old transcript's pending text is then
/// emitted as it stood and the new one is segmented from its start (`isRestart`).
///
/// Pure value type so the rules can be unit-tested without a recognizer.
public struct TranscriptSegmenter {
    public var clauseSplitCharacters = 90
    public var maxSegmentCharacters = 160
    public var maxPendingDuration: TimeInterval = 4.5
    public var minWordsForTimeCut = 8
    public var silenceFlushInterval: TimeInterval = 0.9
    /// A terminator at the very end of the transcript counts only once more text follows it:
    /// SFSpeechRecognizer puts provisional periods there and takes them back ("for Irene." →
    /// "for Irene Adler").
    public var terminatorNeedsFollowingText = false

    public private(set) var transcript: [Character] = []
    public private(set) var committed = 0
    public private(set) var lastUpdate: Date
    public private(set) var pendingSince: Date?
    public private(set) var runStartedAt: Date

    /// The transcript prefix that was already emitted, used to re-anchor after upstream revisions.
    private var committedText: [Character] = []
    /// The transcript before the last restart (all emitted), to recognise late revisions of it.
    private var previousUtterance: [Character] = []

    private static let terminators: Set<Character> = [".", "?", "!", "。", "？", "！"]
    private static let clauseMarks: Set<Character> = [",", ";", ":", "，", "；"]
    private static let anchorLength = 12

    public init(now: Date = Date()) {
        lastUpdate = now
        runStartedAt = now
    }

    /// Text not yet emitted.
    public var uncommitted: String {
        committed < transcript.count ? String(transcript[committed...]) : ""
    }

    public var hasPending: Bool {
        !uncommitted.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Start a fresh run (new recognition task). Nothing pending survives; call `flush()` first.
    public mutating func reset(now: Date = Date()) {
        transcript = []
        committed = 0
        committedText = []
        previousUtterance = []
        pendingSince = nil
        lastUpdate = now
        runStartedAt = now
    }

    /// Feed the latest (revised) transcript of the current run; returns chunks ready to translate.
    public mutating func update(transcript text: String, now: Date = Date()) -> [String] {
        let new = Array(text)
        var out: [String] = []
        if !previousUtterance.isEmpty, Self.isRestart(from: new, to: transcript) || transcript.isEmpty,
           Self.firstWord(new) == Self.firstWord(previousUtterance) {
            // A late revision of the utterance before the restart, all of it emitted already:
            // only words it adds go out.
            let rest = ReportedText.remainder(of: text, after: String(previousUtterance))
            previousUtterance = new
            lastUpdate = now
            return clean(rest)
        }
        if Self.isRestart(from: transcript, to: new) {
            out += clean(uncommitted)
            previousUtterance = transcript
            committed = 0
            committedText = []
        }
        transcript = new
        lastUpdate = now
        reanchorIfRevised()

        // 1. Complete sentences.
        var i = committed
        var lastCut = committed
        while i < transcript.count {
            if Self.terminators.contains(transcript[i]),
               !terminatorNeedsFollowingText || transcript[(i + 1)...].contains(where: { !$0.isWhitespace && !Self.terminators.contains($0) }) {
                out.append(contentsOf: clean(String(transcript[lastCut...i])))
                lastCut = i + 1
            }
            i += 1
        }
        setCommitted(lastCut)

        // 2. Long sentence still in progress: cut at a clause boundary, then at the last space
        //    before the length limit.
        let pending = transcript.count - committed
        if pending > clauseSplitCharacters {
            let tail = transcript[committed...]
            let minCut = committed + 40
            if let cut = tail.lastIndex(where: { Self.clauseMarks.contains($0) }), cut > minCut {
                out.append(contentsOf: clean(String(tail[committed...cut])))
                setCommitted(cut + 1)
            } else if pending > maxSegmentCharacters,
                      let cut = tail.prefix(maxSegmentCharacters).lastIndex(where: { $0 == " " }), cut > minCut {
                out.append(contentsOf: clean(String(tail[committed..<cut])))
                setCommitted(cut + 1)
            }
        }
        refreshPendingClock(now: now)
        return out
    }

    /// Time-based cut: pending text has waited too long. Prefers a clause mark; otherwise leaves
    /// the last two words pending so a sentence tail rarely ends up as a lone word.
    public mutating func cutByTime(now: Date = Date()) -> String? {
        guard let since = pendingSince, now.timeIntervalSince(since) > maxPendingDuration else { return nil }
        let tail = transcript[committed...]
        let words = tail.split(separator: " ").count
        guard words >= minWordsForTimeCut else { return nil }
        let minCut = committed + 20
        // A clause mark right at the start (", but she…" after a revision) is no place to cut:
        // fall back to words rather than waiting for ever.
        let clause = tail.lastIndex(where: { Self.clauseMarks.contains($0) }).map { $0 + 1 }.flatMap { $0 > minCut ? $0 : nil }
        let spaces = tail.indices.filter { tail[$0] == " " }
        let byWords = spaces.count >= 2 ? spaces[spaces.count - 2] : nil
        guard let cut = clause ?? byWords, cut > minCut else { return nil }
        let chunk = clean(String(tail[committed..<cut])).first
        setCommitted(cut)
        // The words left pending get a full `maxPendingDuration` too; keeping the old clock
        // cut again as soon as `minWordsForTimeCut` words piled up (every ~2 s).
        pendingSince = nil
        refreshPendingClock(now: now)
        return chunk
    }

    /// Everything pending, marking it committed.
    public mutating func flush() -> String? {
        let rest = uncommitted
        setCommitted(transcript.count)
        pendingSince = nil
        return clean(rest).first
    }

    /// Everything pending but its last word, which may still grow ("intro" → "introduce"); a
    /// last word ending a sentence or clause goes too. The kept word stays pending.
    public mutating func flushKeepingLastWord() -> String? {
        guard hasPending else { return nil }
        if let last = transcript.last, Self.terminators.contains(last) || Self.clauseMarks.contains(last) {
            return flush()
        }
        let tail = transcript[committed...]
        guard let cut = tail.lastIndex(where: { $0 == " " }) else { return nil }
        let head = clean(String(tail[committed..<cut])).first
        setCommitted(cut)
        pendingSince = nil
        return head
    }

    public func shouldFlushForSilence(now: Date = Date()) -> Bool {
        hasPending && now.timeIntervalSince(lastUpdate) > silenceFlushInterval
    }

    // MARK: Internals

    /// Moves the offset past any whitespace and remembers the committed text.
    private mutating func setCommitted(_ index: Int) {
        var i = min(index, transcript.count)
        while i < transcript.count, transcript[i] == " " { i += 1 }
        committed = i
        committedText = Array(transcript[..<i])
    }

    /// If the recognizer rewrote text before `committed`, find the tail of what we emitted in
    /// the new transcript and continue after it.
    private mutating func reanchorIfRevised() {
        guard committed > 0 else { return }
        if committed <= transcript.count, Array(transcript[..<committed]) == committedText { return }
        // Align the emitted words with the new text (a word rewritten, a comma dropped). A
        // character anchor can match the same words ending an earlier sentence ("she will do
        // it. I know that she will do it.") and repeat what follows; it is only the fallback.
        let text = String(transcript)
        let rest = ReportedText.remainder(of: text, after: String(committedText))
        if text.hasSuffix(rest) {
            setCommitted(transcript.count - rest.count)
            return
        }
        let anchor = Array(committedText.suffix(Self.anchorLength))
        if !anchor.isEmpty, let end = lastOccurrenceEnd(of: anchor, in: transcript) {
            setCommitted(end)
        } else {
            committed = min(committed, transcript.count)
        }
    }

    /// A new utterance rather than a revision: much shorter, and it starts with another word.
    static func isRestart(from old: [Character], to new: [Character]) -> Bool {
        guard new.count * 2 < old.count else { return false }
        let a = firstWord(old), b = firstWord(new)
        return !a.isEmpty && !b.isEmpty && a != b
    }

    private static func firstWord(_ c: [Character]) -> String {
        String(c.prefix { !$0.isWhitespace }).lowercased().trimmingCharacters(in: .punctuationCharacters)
    }

    private func lastOccurrenceEnd(of needle: [Character], in haystack: [Character]) -> Int? {
        guard needle.count <= haystack.count else { return nil }
        var start = haystack.count - needle.count
        while start >= 0 {
            if Array(haystack[start..<start + needle.count]) == needle { return start + needle.count }
            start -= 1
        }
        return nil
    }

    private mutating func refreshPendingClock(now: Date) {
        if !hasPending {
            pendingSince = nil
        } else if pendingSince == nil {
            pendingSince = now
        }
    }

    private func clean(_ raw: String) -> [String] {
        // A mark the recognizer added after the words before it went out (", but…") leads nothing.
        var text = Substring(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        while let first = text.first, Self.clauseMarks.contains(first) || Self.terminators.contains(first) {
            text = text.dropFirst().drop(while: \.isWhitespace)
        }
        // A lone mark (a period added after the words went out) is nothing to say.
        return text.contains(where: { $0.isLetter || $0.isNumber }) ? [String(text)] : []
    }
}
