import Foundation

/// Cuts text that was already reported out of a recognizer result that repeats it.
///
/// SpeechAnalyzer keeps revising an utterance while it is volatile. When the pipeline rotates
/// the run mid-utterance it has already emitted what the volatile text said so far, and the next
/// results of the same utterance start with that text again — *revised*: words corrected,
/// punctuation added, "particular" grown into "particularly". Trimming by character count
/// (what the engine did) lands mid-word as soon as anything before the cut changes, and emits
/// fragments such as "er, all emotions, and that one particular…" twice.
///
/// Instead the reported words are aligned with the new result (longest common subsequence,
/// ignoring case and punctuation, a reported word also matching one it is a prefix of) and
/// everything up to where the reported text ends is dropped.
public enum ReportedText {
    public static func remainder(of text: String, after reported: String) -> String {
        let reportedWords = reported.split(whereSeparator: \.isWhitespace).map(normalize).filter { !$0.isEmpty }
        guard !reportedWords.isEmpty else { return text }
        let tokens = text.split(whereSeparator: \.isWhitespace)
        let words = tokens.map(normalize)
        // The reported text can only be near the start of the result.
        let window = min(words.count, reportedWords.count + 12)
        let r = reportedWords.count

        // LCS table over reported words × the first `window` result words.
        var lcs = Array(repeating: Array(repeating: 0, count: window + 1), count: r + 1)
        for i in stride(from: r - 1, through: 0, by: -1) {
            for j in stride(from: window - 1, through: 0, by: -1) {
                lcs[i][j] = matches(reportedWords[i], words[j])
                    ? lcs[i + 1][j + 1] + 1
                    : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }
        // Walk the alignment; remember the last matched pair.
        var i = 0, j = 0
        var last: (r: Int, t: Int)?
        while i < r, j < window {
            if matches(reportedWords[i], words[j]), lcs[i][j] == lcs[i + 1][j + 1] + 1 {
                last = (i, j); i += 1; j += 1
            } else if lcs[i + 1][j] >= lcs[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        let cut: Int
        if let last {
            // Reported words after the last match were revised away: skip as many result words.
            cut = min(tokens.count, last.t + 1 + (r - 1 - last.r))
        } else {
            cut = min(tokens.count, r)
        }
        return tokens[cut...].joined(separator: " ")
    }

    /// End of the last sentence in `text` that speech has already moved past ("… home. And
    /// then" → after "home."), so a sentence still being spoken is never cut. An abbreviation
    /// such as "Mr." counts only once more words follow it — acceptable for the fallback it serves.
    public static func endOfCompletedSentences(in text: String) -> String.Index? {
        lastBoundary(in: text, marks: ".?!")
    }

    /// Like `endOfCompletedSentences`, also accepting clause marks (`, ; :`): the fallback when a
    /// recognizer merged two sentences and dropped the period between them ("… than before, as
    /// he stepped up to the cab, …").
    public static func endOfCompletedClauses(in text: String) -> String.Index? {
        lastBoundary(in: text, marks: ".?!,;:")
    }

    /// The end of all but the last `keep` words, when `text` has at least `minWords` words — the
    /// last resort for long unpunctuated speech; the kept words may still be revised.
    public static func endKeepingLastWords(in text: String, keep: Int = 3, minWords: Int = 15) -> String.Index? {
        let spaces = text.indices.filter { text[$0].isWhitespace && $0 > text.startIndex && !text[text.index(before: $0)].isWhitespace }
        guard spaces.count + 1 >= minWords, spaces.count >= keep else { return nil }
        return spaces[spaces.count - keep]
    }

    private static func lastBoundary(in text: String, marks: String) -> String.Index? {
        var result: String.Index?
        var i = text.startIndex
        while i < text.endIndex {
            let next = text.index(after: i)
            if marks.contains(text[i]), next < text.endIndex, text[next].isWhitespace,
               text[next...].contains(where: { $0.isLetter }) {
                result = next
            }
            i = next
        }
        return result
    }

    private static func normalize<S: StringProtocol>(_ word: S) -> String {
        String(word.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "'" })
    }

    private static func matches(_ reported: String, _ word: String) -> Bool {
        reported == word || (reported.count >= 4 && word.hasPrefix(reported))
    }
}
