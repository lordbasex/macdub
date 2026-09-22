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
/// Pure value type so the rules can be unit-tested without a recognizer.
public struct TranscriptSegmenter {
    public var clauseSplitCharacters = 90
    public var maxSegmentCharacters = 160
    public var maxPendingDuration: TimeInterval = 4.5
    public var minWordsForTimeCut = 8
    public var silenceFlushInterval: TimeInterval = 0.9

    public private(set) var transcript: [Character] = []
    public private(set) var committed = 0
    public private(set) var lastUpdate: Date
    public private(set) var pendingSince: Date?
    public private(set) var runStartedAt: Date

    /// The transcript prefix that was already emitted, used to re-anchor after upstream revisions.
    private var committedText: [Character] = []

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
        pendingSince = nil
        lastUpdate = now
        runStartedAt = now
    }

    /// Feed the latest (revised) transcript of the current run; returns chunks ready to translate.
    public mutating func update(transcript text: String, now: Date = Date()) -> [String] {
        transcript = Array(text)
        lastUpdate = now
        reanchorIfRevised()
        var out: [String] = []

        // 1. Complete sentences.
        var i = committed
        var lastCut = committed
        while i < transcript.count {
            if Self.terminators.contains(transcript[i]) {
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
        let clause = tail.lastIndex(where: { Self.clauseMarks.contains($0) }).map { $0 + 1 }
        let spaces = tail.indices.filter { tail[$0] == " " }
        let byWords = spaces.count >= 2 ? spaces[spaces.count - 2] : nil
        guard let cut = clause ?? byWords, cut > committed + 20 else { return nil }
        let chunk = clean(String(tail[committed..<cut])).first
        setCommitted(cut)
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
        let anchor = Array(committedText.suffix(Self.anchorLength))
        guard !anchor.isEmpty, let end = lastOccurrenceEnd(of: anchor, in: transcript) else {
            committed = min(committed, transcript.count)
            return
        }
        setCommitted(end)
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
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? [] : [text]
    }
}
