import Testing
import Foundation
import MacDubCore

@Suite struct VoiceCatchUpTests {
    @Test func noBacklogKeepsBaseRate() {
        #expect(SpeechRate.catchUp(base: 0.5, backlog: 0, boost: 0.15, maxFactor: 1.6) == 0.5)
    }

    @Test func boostPerQueuedSentence() {
        let r = SpeechRate.catchUp(base: 0.5, backlog: 2, boost: 0.15, maxFactor: 1.6)
        #expect(abs(r - 0.5 * 1.3) < 0.0001)
    }

    @Test func cappedAtMaxFactor() {
        let r = SpeechRate.catchUp(base: 0.5, backlog: 10, boost: 0.15, maxFactor: 1.6)
        #expect(abs(r - 0.8) < 0.0001)
    }

    @Test func neverAboveSynthesizerMaximum() {
        let r = SpeechRate.catchUp(base: 0.9, backlog: 10, boost: 0.5, maxFactor: 3, maximum: 1)
        #expect(r == 1)
    }

    @Test func zeroBoostNeverSpeedsUp() {
        #expect(SpeechRate.catchUp(base: 0.55, backlog: 7, boost: 0, maxFactor: 1.4) == 0.55)
    }
}

@Suite struct TranscriptExporterTests {
    @Test func srtTimeFormatting() {
        #expect(TranscriptExporter.srtTime(0) == "00:00:00,000")
        #expect(TranscriptExporter.srtTime(61.5) == "00:01:01,500")
        #expect(TranscriptExporter.srtTime(3725.25) == "01:02:05,250")
        #expect(TranscriptExporter.srtTime(-3) == "00:00:00,000")
    }

    @Test func srtCuesAreSequentialAndNonOverlapping() {
        // Segment timestamps are set at init, so the session start is placed 10 s in the past.
        let a = Segment(original: "Hello.", translated: "Hola.")
        let b = Segment(original: "World.", translated: "Mundo.")
        let out = TranscriptExporter.render([a, b], format: .srt, content: .translated,
                                            sessionStart: Date().addingTimeInterval(-10))
        let blocks = out.split(separator: "\n\n").map(String.init)
        #expect(blocks.count == 2)
        #expect(blocks[0].hasPrefix("1\n"))
        #expect(blocks[1].hasPrefix("2\n"))
        #expect(blocks[0].contains("Hola."))
        #expect(!blocks[0].contains("Hello."), "translated-only content")
        #expect(blocks[0].contains(" --> "))

        // Second cue starts where the first ended.
        let end1 = blocks[0].split(separator: "\n")[1].components(separatedBy: " --> ")[1]
        let start2 = blocks[1].split(separator: "\n")[1].components(separatedBy: " --> ")[0]
        #expect(end1 == start2)
    }

    @Test func bothContentIncludesOriginalAndTranslation() {
        let s = Segment(original: "Hello.", translated: "Hola.")
        let out = TranscriptExporter.render([s], format: .txt, content: .both,
                                            sessionStart: Date().addingTimeInterval(-5))
        #expect(out.contains("Hello."))
        #expect(out.contains("Hola."))
        #expect(out.hasPrefix("[00:00:0"))
    }
}
