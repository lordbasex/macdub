import Testing
import Foundation
import MacDubCore

// Swift Testing (not XCTest): it ships with the Command Line Tools, XCTest does not.
@Suite struct TranscriptSegmenterTests {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test func emitsSentenceAsSoonAsTerminatorAppears() {
        var s = TranscriptSegmenter(now: t0)
        #expect(s.update(transcript: "Hello there", now: t0) == [])
        #expect(s.update(transcript: "Hello there. How", now: t0) == ["Hello there."])
        #expect(s.uncommitted == "How")
        #expect(s.update(transcript: "Hello there. How are you?", now: t0) == ["How are you?"])
        #expect(s.uncommitted == "")
    }

    @Test func revisionInsideCommittedRegionIsIgnored() {
        var s = TranscriptSegmenter(now: t0)
        _ = s.update(transcript: "I became a psychologist. Then", now: t0)
        // The recognizer rewrites the already-emitted sentence; only the tail is pending.
        let out = s.update(transcript: "I became a clinical psychologist. Then I", now: t0)
        #expect(out == [])
        #expect(s.uncommitted == "Then I")
    }

    @Test func revisionThatShortensCommittedRegionIsIgnored() {
        var s = TranscriptSegmenter(now: t0)
        _ = s.update(transcript: "So the the message is simple. Next", now: t0)
        let out = s.update(transcript: "So the message is simple. Next up", now: t0)
        #expect(out == [])
        #expect(s.uncommitted == "Next up")
    }

    @Test func multipleSentencesInOneUpdate() {
        var s = TranscriptSegmenter(now: t0)
        #expect(s.update(transcript: "One. Two! Three? Four", now: t0) == ["One.", "Two!", "Three?"])
        #expect(s.uncommitted.trimmingCharacters(in: .whitespaces) == "Four")
    }

    @Test func clauseSplitWhenSentenceRunsLong() {
        var s = TranscriptSegmenter(now: t0)
        s.clauseSplitCharacters = 40
        let text = "This is a rather long clause that keeps going, and then it continues with more words"
        let out = s.update(transcript: text, now: t0)
        #expect(out == ["This is a rather long clause that keeps going,"])
        #expect(s.uncommitted == "and then it continues with more words")
    }

    @Test func spaceSplitWhenNoPunctuationAtAll() {
        var s = TranscriptSegmenter(now: t0)
        s.clauseSplitCharacters = 30
        s.maxSegmentCharacters = 50
        let text = "word word word word word word word word word word word word word"
        let out = s.update(transcript: text, now: t0)
        #expect(out.count == 1)
        #expect(out[0].count >= 40 && out[0].count <= 50, "cut near the limit, got \(out[0].count)")
        #expect(!out[0].hasSuffix(" "))
        #expect(!s.uncommitted.hasPrefix(" "))
    }

    @Test func timeCutLeavesLastTwoWordsPending() {
        var s = TranscriptSegmenter(now: t0)
        s.maxPendingDuration = 3
        s.minWordsForTimeCut = 5
        _ = s.update(transcript: "one two three four five six seven eight", now: t0)
        #expect(s.cutByTime(now: t0.addingTimeInterval(2)) == nil, "too early")
        #expect(s.cutByTime(now: t0.addingTimeInterval(3.5)) == "one two three four five six")
        #expect(s.uncommitted == "seven eight")
    }

    @Test func timeCutPrefersClauseMark() {
        var s = TranscriptSegmenter(now: t0)
        s.maxPendingDuration = 1
        s.minWordsForTimeCut = 5
        _ = s.update(transcript: "as long as you have a heads up, you expect us to be there", now: t0)
        #expect(s.cutByTime(now: t0.addingTimeInterval(2)) == "as long as you have a heads up,")
        #expect(s.uncommitted == "you expect us to be there")
    }

    @Test func timeCutRequiresMinimumWords() {
        var s = TranscriptSegmenter(now: t0)
        s.maxPendingDuration = 1
        s.minWordsForTimeCut = 8
        _ = s.update(transcript: "only a few words here", now: t0)
        #expect(s.cutByTime(now: t0.addingTimeInterval(5)) == nil)
    }

    @Test func silenceFlush() {
        var s = TranscriptSegmenter(now: t0)
        s.silenceFlushInterval = 0.9
        _ = s.update(transcript: "pending words", now: t0)
        #expect(!s.shouldFlushForSilence(now: t0.addingTimeInterval(0.5)))
        #expect(s.shouldFlushForSilence(now: t0.addingTimeInterval(1.0)))
        #expect(s.flush() == "pending words")
        #expect(!s.hasPending)
        #expect(s.flush() == nil, "nothing left")
        #expect(!s.shouldFlushForSilence(now: t0.addingTimeInterval(10)), "no pending text, no flush")
    }

    @Test func resetStartsNewRun() {
        var s = TranscriptSegmenter(now: t0)
        _ = s.update(transcript: "First run text.", now: t0)
        s.reset(now: t0.addingTimeInterval(1))
        #expect(s.uncommitted == "")
        #expect(s.update(transcript: "Second run.", now: t0.addingTimeInterval(1)) == ["Second run."])
    }

    @Test func pendingClockStartsWhenTextAppearsAndClearsWhenCommitted() {
        var s = TranscriptSegmenter(now: t0)
        #expect(s.pendingSince == nil)
        _ = s.update(transcript: "hello", now: t0)
        #expect(s.pendingSince == t0)
        _ = s.update(transcript: "hello world", now: t0.addingTimeInterval(1))
        #expect(s.pendingSince == t0, "clock keeps the first appearance")
        _ = s.update(transcript: "hello world.", now: t0.addingTimeInterval(2))
        #expect(s.pendingSince == nil)
    }
}
