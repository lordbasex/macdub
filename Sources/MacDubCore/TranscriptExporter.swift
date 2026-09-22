import Foundation

/// Serializes the session transcript as SubRip (.srt), Markdown (.md) or plain text.
///
/// Timing: `Segment.recognizedAt` is when a sentence was *cut* from the transcript, i.e. roughly
/// when the speaker finished it. A cue therefore runs from the previous cue's end to its own
/// `recognizedAt`, which lines up well with the audio when the exported file is loaded next to
/// the original video (offsets are relative to `sessionStart`).
public enum TranscriptExporter {
    public enum Format: String, CaseIterable, Identifiable {
        case srt, md, txt
        public var id: String { rawValue }
        public var fileExtension: String { rawValue }
    }

    public enum Content { case translated, original, both }

    /// Session facts written into the Markdown/text headers.
    public struct Metadata {
        public var appName: String?
        public var sourceLanguage: String?
        public var targetLanguage: String?
        public init(appName: String? = nil, sourceLanguage: String? = nil, targetLanguage: String? = nil) {
            self.appName = appName
            self.sourceLanguage = sourceLanguage
            self.targetLanguage = targetLanguage
        }
    }

    public static func render(_ segments: [Segment], format: Format, content: Content,
                              sessionStart: Date, metadata: Metadata = Metadata()) -> String {
        switch format {
        case .srt: return srt(segments, content: content, sessionStart: sessionStart)
        case .md: return markdown(segments, content: content, sessionStart: sessionStart, metadata: metadata)
        case .txt: return txt(segments, content: content, sessionStart: sessionStart)
        }
    }

    private static func lines(for segment: Segment, content: Content) -> [String] {
        switch content {
        case .translated: return [segment.translated ?? segment.original]
        case .original: return [segment.original]
        case .both: return [segment.original] + (segment.translated.map { [$0] } ?? [])
        }
    }

    /// When one sentence is on screen, in seconds from the session start.
    public struct Cue: Equatable {
        public var start: TimeInterval
        public var end: TimeInterval
        public init(start: TimeInterval, end: TimeInterval) {
            self.start = start
            self.end = end
        }
        public var duration: TimeInterval { end - start }
        public func contains(_ t: TimeInterval) -> Bool { t >= start && t < end }
        /// 0 at `start`, 1 at `end`, clamped.
        public func progress(at t: TimeInterval) -> Double {
            guard duration > 0 else { return 1 }
            return min(1, max(0, (t - start) / duration))
        }
    }

    /// One cue per segment: from the previous cue's end to the segment's `recognizedAt`, never
    /// shorter than half a second and never stretching back more than 6 s after a long gap. The
    /// SRT export and the History player share this timing so what VLC shows is what MacDub shows.
    public static func cues(for segments: [Segment], sessionStart: Date) -> [Cue] {
        var out: [Cue] = []
        var previousEnd: TimeInterval = 0
        for segment in segments {
            let end = max(segment.recognizedAt.timeIntervalSince(sessionStart), previousEnd + 0.5)
            let start = max(previousEnd, end - 6)
            out.append(Cue(start: start, end: end))
            previousEnd = end
        }
        return out
    }

    private static func srt(_ segments: [Segment], content: Content, sessionStart: Date) -> String {
        var out = ""
        for (i, (segment, cue)) in zip(segments, cues(for: segments, sessionStart: sessionStart)).enumerated() {
            out += "\(i + 1)\n\(srtTime(cue.start)) --> \(srtTime(cue.end))\n"
            out += lines(for: segment, content: content).joined(separator: "\n") + "\n\n"
        }
        return out
    }

    private static func txt(_ segments: [Segment], content: Content, sessionStart: Date) -> String {
        segments.map { segment in
            let t = segment.recognizedAt.timeIntervalSince(sessionStart)
            return "[\(clock(t))] " + lines(for: segment, content: content).joined(separator: "\n    ")
        }
        .joined(separator: "\n")
    }

    /// Markdown meant to be pasted into (or read by) an LLM: a small header with the session
    /// facts, then one bullet per sentence with the original and, as a quote, the translation.
    private static func markdown(_ segments: [Segment], content: Content, sessionStart: Date, metadata: Metadata) -> String {
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short
        var out = "# MacDub transcript\n\n"
        if let app = metadata.appName { out += "- **Source app:** \(app)\n" }
        if let s = metadata.sourceLanguage, let t = metadata.targetLanguage { out += "- **Languages:** \(s) → \(t)\n" }
        out += "- **Session start:** \(df.string(from: sessionStart))\n"
        out += "- **Sentences:** \(segments.count)\n\n"
        out += "## Transcript\n\n"
        for segment in segments {
            let t = clock(segment.recognizedAt.timeIntervalSince(sessionStart))
            switch content {
            case .original:
                out += "- `\(t)` \(segment.original)\n"
            case .translated:
                out += "- `\(t)` \(segment.translated ?? segment.original)\n"
            case .both:
                out += "- `\(t)` \(segment.original)\n"
                if let tr = segment.translated { out += "  > \(tr)\n" }
            }
        }
        return out
    }

    public static func srtTime(_ t: TimeInterval) -> String {
        let total = max(0, t)
        let h = Int(total / 3600)
        let m = Int(total.truncatingRemainder(dividingBy: 3600) / 60)
        let s = Int(total.truncatingRemainder(dividingBy: 60))
        let ms = Int((total - floor(total)) * 1000)
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, ms)
    }

    public static func clock(_ t: TimeInterval) -> String {
        let total = Int(max(0, t))
        return String(format: "%02d:%02d:%02d", total / 3600, total % 3600 / 60, total % 60)
    }
}
