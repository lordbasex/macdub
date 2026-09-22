import SwiftUI

/// Karaoke-style text: what the voice already said in `spokenColor`, the word being pronounced
/// in `currentColor` and bold, the rest in `baseColor`.
struct SpokenText: View {
    let text: String
    /// UTF-16 range of the current word (as reported by `AVSpeechSynthesizer`), nil = not speaking.
    let word: NSRange?
    var baseColor: Color = .primary
    var spokenColor: Color = .accentColor
    var currentColor: Color = .accentColor
    var font: Font = .body

    var body: some View {
        Text(attributed)
            .font(font)
    }

    private var attributed: AttributedString {
        guard let word, let range = Range(word, in: text) else {
            var whole = AttributedString(text)
            whole.foregroundColor = baseColor
            return whole
        }
        var before = AttributedString(String(text[..<range.lowerBound]))
        before.foregroundColor = spokenColor
        var current = AttributedString(String(text[range]))
        current.foregroundColor = currentColor
        current.inlinePresentationIntent = .stronglyEmphasized
        var after = AttributedString(String(text[range.upperBound...]))
        after.foregroundColor = baseColor
        return before + current + after
    }
}
