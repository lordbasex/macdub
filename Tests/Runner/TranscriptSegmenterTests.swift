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

    @Test func restartedTranscriptKeepsPendingTextAndNewStart() {
        var s = TranscriptSegmenter(now: t0)
        _ = s.update(transcript: "He was at work again. He had risen out of his drug created dreams", now: t0)
        // SFSpeechRecognizer starts a new utterance within the same task after a pause.
        #expect(s.update(transcript: "I", now: t0) == ["He had risen out of his drug created dreams"])
        #expect(s.uncommitted == "I")
        #expect(s.update(transcript: "I rang the bell.", now: t0) == ["I rang the bell."])
    }

    @Test func lateRevisionOfThePreviousUtteranceIsNotRepeated() {
        var s = TranscriptSegmenter(now: t0)
        _ = s.update(transcript: "I rang the bell and was shown up. Then he stood before the fire", now: t0)
        #expect(s.update(transcript: "Re", now: t0) == ["Then he stood before the fire"])
        // SFSpeechRecognizer sends a revised full version of the utterance it restarted from.
        #expect(s.update(transcript: "I rang the bell and was shown up. Then he stood before the fire.", now: t0) == [])
        #expect(s.update(transcript: "Red suits you", now: t0) == [])
        #expect(s.uncommitted == "Red suits you")
    }

    @Test func punctuationAloneIsNotASegment() {
        var s = TranscriptSegmenter(now: t0)
        _ = s.update(transcript: "was not abusive", now: t0)
        #expect(s.flush() == "was not abusive")
        #expect(s.update(transcript: "was not abusive. It", now: t0) == [])
    }

    @Test func restartWithNothingCommittedKeepsEverything() {
        var s = TranscriptSegmenter(now: t0)
        _ = s.update(transcript: "to me who is every moon and Abbott", now: t0)
        #expect(s.update(transcript: "His", now: t0) == ["to me who is every moon and Abbott"])
        #expect(s.uncommitted == "His")
    }

    @Test func shorteningRevisionIsNotARestart() {
        var s = TranscriptSegmenter(now: t0)
        _ = s.update(transcript: "So the the the the message", now: t0)
        #expect(s.update(transcript: "So", now: t0) == [])
        #expect(s.uncommitted == "So")
    }

    @Test func revisionOfTheCommittedEndRealignsByWords() {
        var s = TranscriptSegmenter(now: t0)
        _ = s.update(transcript: "and finally of the mission, which because", now: t0)
        #expect(s.flush() == "and finally of the mission, which because")
        _ = s.update(transcript: "and finally of the mission which has accomplished so", now: t0)
        #expect(s.uncommitted == "accomplished so")
    }

    @Test func anchorRepeatedEarlierIsNotUsed() {
        var s = TranscriptSegmenter(now: t0)
        s.terminatorNeedsFollowingText = true
        _ = s.update(transcript: "Threatens to send the photograph and she will do it. I know that she will do it.", now: t0)
        #expect(s.flush() == "I know that she will do it.")
        // The last period goes away: "will do it." now only matches the first sentence.
        _ = s.update(transcript: "Threatens to send the photograph and she will do it. I know that she will do it you", now: t0)
        #expect(s.uncommitted == "you")
        #expect(s.update(transcript: "Threatens to send the photograph and she will do it. I know that she will do it. You do not. Know", now: t0) == ["You do not."])
    }

    @Test func flushKeepingLastWordLetsItGrow() {
        var s = TranscriptSegmenter(now: t0)
        _ = s.update(transcript: "His temperament was to intro", now: t0)
        #expect(s.flushKeepingLastWord() == "His temperament was to")
        #expect(s.update(transcript: "His temperament was to introduce a.", now: t0) == ["introduce a."])
    }

    @Test func flushKeepingLastWordKeepsALoneWord() {
        var s = TranscriptSegmenter(now: t0)
        _ = s.update(transcript: "Acting", now: t0)
        #expect(s.flushKeepingLastWord() == nil)
        #expect(s.uncommitted == "Acting")
        _ = s.update(transcript: "Ends here,", now: t0)
        #expect(s.flushKeepingLastWord() == "Ends here,")
    }

    @Test func provisionalTerminatorWaitsForFollowingText() {
        var s = TranscriptSegmenter(now: t0)
        s.terminatorNeedsFollowingText = true
        #expect(s.update(transcript: "Any emotion for Irene.", now: t0) == [])
        #expect(s.update(transcript: "Any emotion for Irene Adler.", now: t0) == [])
        #expect(s.update(transcript: "Any emotion for Irene Adler. All", now: t0) == ["Any emotion for Irene Adler."])
        #expect(s.uncommitted == "All")
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
        _ = s.update(transcript: "one two three four five six seven eight nine ten eleven twelve thirteen", now: t0.addingTimeInterval(4))
        #expect(s.cutByTime(now: t0.addingTimeInterval(5)) == nil, "the clock restarted at the cut")
        #expect(s.cutByTime(now: t0.addingTimeInterval(7)) == "seven eight nine ten eleven")
    }

    @Test func timeCutPrefersClauseMark() {
        var s = TranscriptSegmenter(now: t0)
        s.maxPendingDuration = 1
        s.minWordsForTimeCut = 5
        _ = s.update(transcript: "as long as you have a heads up, you expect us to be there", now: t0)
        #expect(s.cutByTime(now: t0.addingTimeInterval(2)) == "as long as you have a heads up,")
        #expect(s.uncommitted == "you expect us to be there")
    }

    @Test func timeCutIgnoresALeadingClauseMark() {
        var s = TranscriptSegmenter(now: t0)
        _ = s.update(transcript: "You do not know her", now: t0)
        #expect(s.flush() == "You do not know her")
        s.maxPendingDuration = 1
        _ = s.update(transcript: "You do not know her, but she has a soul of steel she has the face of the most beautiful", now: t0)
        #expect(s.cutByTime(now: t0.addingTimeInterval(2)) == "but she has a soul of steel she has the face of the")
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

@Suite struct ReportedTextTests {
    @Test func unchangedPrefixIsDropped() {
        #expect(ReportedText.remainder(of: "It was not that he felt any emotion", after: "It was not") == "that he felt any emotion")
    }

    // The case the benchmark caught: the character-count trim emitted "er, all emotions, …" twice.
    @Test func revisedTextIsCutAtTheRightWord() {
        let reported = "to love for Irene Adler all emotions and that one particular"
        let revised = "to love for Irene Adler. All emotions, and that one particularly, were abhorrent to his cold,"
        #expect(ReportedText.remainder(of: revised, after: reported) == "were abhorrent to his cold,")
    }

    @Test func correctedWordsDoNotShiftTheCut() {
        let reported = "In his I she eclipses and predomin"
        let revised = "In his eyes she eclipses and predominates the whole of her sex."
        #expect(ReportedText.remainder(of: revised, after: reported) == "the whole of her sex.")
    }

    @Test func nothingReportedKeepsEverything() {
        #expect(ReportedText.remainder(of: "Hello there.", after: "") == "Hello there.")
    }

    @Test func fullyReportedLeavesNothing() {
        #expect(ReportedText.remainder(of: "Hello there.", after: "hello there") == "")
    }

    @Test func unrelatedResultFallsBackToWordCount() {
        #expect(ReportedText.remainder(of: "completely different words here now", after: "alpha beta") == "words here now")
    }
}

@Suite struct CompletedSentencesTests {
    private func head(_ text: String) -> String? {
        ReportedText.endOfCompletedSentences(in: text).map { String(text[..<$0]) }
    }

    @Test func sentenceFollowedBySpeechIsComplete() {
        #expect(head("I asked. He said nothing") == "I asked.")
    }

    @Test func lastOfSeveralCompletedSentences() {
        #expect(head("Yes. Why? Because it is late! And") == "Yes. Why? Because it is late!")
    }

    @Test func sentenceStillBeingSpokenIsNot() {
        #expect(head("He waited for the whole of") == nil)
        #expect(head("He waited.") == nil)   // nothing after it yet: the final may still revise it
    }

    @Test func numbersAreNotSentenceEnds() {
        #expect(head("It costs 3.5 dollars and") == nil)
    }
}

@Suite struct LatencyCapBoundaryTests {
    private func head(_ text: String, _ end: String.Index?) -> String? { end.map { String(text[..<$0]) } }

    // The benchmark case: SpeechAnalyzer dropped the period and joined two sentences with a comma.
    @Test func clauseMarkEndsTheHead() {
        let t = "Presly he emerged, looking even more flurried than before, as he stepped up"
        #expect(head(t, ReportedText.endOfCompletedClauses(in: t)) == "Presly he emerged, looking even more flurried than before,")
    }

    @Test func noClauseYet() {
        #expect(ReportedText.endOfCompletedClauses(in: "He was in the house about half") == nil)
    }

    @Test func keepsTheLastWordsOfLongUnpunctuatedSpeech() {
        let t = "one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen"
        #expect(head(t, ReportedText.endKeepingLastWords(in: t)) == "one two three four five six seven eight nine ten eleven twelve thirteen")
    }

    @Test func shortSpeechIsLeftAlone() {
        #expect(ReportedText.endKeepingLastWords(in: "only a few words here") == nil)
    }
}
