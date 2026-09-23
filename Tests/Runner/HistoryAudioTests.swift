import Testing
import Foundation
import MacDubCore

@Suite struct CueTimingTests {
    private func segment(_ text: String, at seconds: TimeInterval, from start: Date) -> Segment {
        Segment(original: text, recognizedAt: start.addingTimeInterval(seconds))
    }

    @Test func cuesRunFromPreviousEndToRecognizedAt() {
        let start = Date()
        let segs = [segment("One.", at: 3, from: start), segment("Two.", at: 7, from: start)]
        let cues = TranscriptExporter.cues(for: segs, sessionStart: start)
        #expect(cues == [.init(start: 0, end: 3), .init(start: 3, end: 7)])
    }

    @Test func longGapDoesNotStretchBackMoreThanSixSeconds() {
        let start = Date()
        let segs = [segment("One.", at: 2, from: start), segment("Two.", at: 40, from: start)]
        let cues = TranscriptExporter.cues(for: segs, sessionStart: start)
        #expect(cues[1].start == 34)
        #expect(cues[1].end == 40)
    }

    @Test func cueIsNeverShorterThanHalfASecond() {
        let start = Date()
        let segs = [segment("One.", at: 2, from: start), segment("Two.", at: 2.1, from: start)]
        let cues = TranscriptExporter.cues(for: segs, sessionStart: start)
        #expect(cues[1].end == 2.5)
    }

    @Test func srtUsesTheSameTiming() {
        let start = Date()
        let segs = [segment("One.", at: 3, from: start), segment("Two.", at: 7, from: start)]
        let srt = TranscriptExporter.render(segs, format: .srt, content: .original, sessionStart: start)
        #expect(srt.contains("00:00:03,000 --> 00:00:07,000"))
    }

    @Test func progressIsClampedInsideTheCue() {
        let cue = TranscriptExporter.Cue(start: 10, end: 14)
        #expect(cue.progress(at: 9) == 0)
        #expect(cue.progress(at: 12) == 0.5)
        #expect(cue.progress(at: 20) == 1)
        #expect(cue.contains(13.9))
        #expect(!cue.contains(14))
    }
}

@Suite struct KaraokeTests {
    @Test func firstWordAtStartLastWordAtEnd() {
        let text = "Hello there, world."
        let first = Karaoke.wordRange(in: text, progress: 0)
        let last = Karaoke.wordRange(in: text, progress: 1)
        #expect(first == NSRange(location: 0, length: 5))
        #expect(last == NSRange(location: 13, length: 5))
    }

    @Test func timeIsSharedInProportionToWordLength() {
        // "a" is 1 of 11 letters: 30 % of the way through we are already in "elephant".
        let text = "a elephant"
        let range = Karaoke.wordRange(in: text, progress: 0.3)
        #expect(range == NSRange(location: 2, length: 8))
    }

    @Test func punctuationOnlyTextHasNoWord() {
        #expect(Karaoke.wordRange(in: "…", progress: 0.5) == nil)
        #expect(Karaoke.wordRange(in: "", progress: 0.5) == nil)
    }
}

@Suite struct SessionRecordTests {
    @Test func exportBaseNameHasNoSpaces() {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 9; comps.day = 22; comps.hour = 19; comps.minute = 11; comps.second = 5
        let date = Calendar.current.date(from: comps)!
        let record = SessionRecord(startedAt: date, appName: "Safari", appBundleIdentifier: nil,
                                   sourceLocale: "en-US", targetLanguage: "es", segments: [])
        #expect(record.exportBaseName() == "macdub-audio-2026-09-22-191105")
        #expect(record.exportBaseName(kind: "transcript") == "macdub-transcript-2026-09-22-191105")
        #expect(!record.exportBaseName().contains(" "))
    }

    @Test func recordsSavedBeforeAudioExistedStillDecode() throws {
        let json = """
        {"id":"abc","startedAt":"2026-09-22T19:11:05Z","endedAt":"2026-09-22T19:12:05Z","appName":"Safari",
         "sourceLocale":"en-US","targetLanguage":"es","segments":[]}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let record = try decoder.decode(SessionRecord.self, from: Data(json.utf8))
        #expect(record.audioFile == nil)
        #expect(record.audioURL == nil)
    }

    @Test func audioURLIsNilWhenTheFileIsGone() {
        let record = SessionRecord(startedAt: Date(), appName: nil, appBundleIdentifier: nil, sourceLocale: "en-US",
                                   targetLanguage: "es", segments: [], audioFile: "does-not-exist.m4a")
        #expect(record.audioURL == nil)
    }
}

@Suite struct SessionPathSafetyTests {
    @Test func uuidsAreValidIDs() {
        #expect(SessionStore.isValidID("DDA6FE15-EC69-4D5D-A7C2-0F01D09CFE28"))
    }

    // What an MCP client could send to delete_session / get_session / export_session.
    @Test func traversalIDsAreRefused() {
        for id in ["../../Claude/claude_desktop_config", "..", "a/b", "", "x\u{0}y", String(repeating: "a", count: 65)] {
            #expect(!SessionStore.isValidID(id))
            #expect(!SessionStore.exists(id: id))
            #expect(throws: (any Error).self) { try SessionStore.delete(id: id) }
        }
    }

    @Test func audioFileMustStayInTheAudioFolder() {
        var r = SessionRecord(id: "A", startedAt: Date(), appName: nil, appBundleIdentifier: nil,
                              sourceLocale: "en-US", targetLanguage: "es", segments: [])
        r.audioFile = "../../Documents/thesis.docx"
        #expect(r.audioURL == nil)
        r.audioFile = ".hidden.m4a"
        #expect(r.audioURL == nil)
    }
}
