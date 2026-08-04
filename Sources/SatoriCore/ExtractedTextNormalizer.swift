import Foundation

/// Cleans up text pulled out of a PDF before it becomes either on-screen
/// context or model input.
///
/// Some PDFs position every glyph independently, so PDFKit hands back strings
/// like "返 回 正 整 数" — a space wedged between characters that were never
/// meant to be separated. Left alone this is both ugly in the "提问依据"
/// preview and noise in the prompt the model reads.
///
/// The one rule we can apply safely: a single space (or run of spaces) sitting
/// *between two CJK characters* is always an artifact, because Chinese and
/// Japanese don't separate characters with spaces. We never touch spaces that
/// border a Latin letter, digit, or symbol, so mixed lines such as
/// "length=10; /*设定 num 的位数*/" and inline code keep their real spacing.
public enum ExtractedTextNormalizer {
    public static func normalize(_ text: String) -> String {
        let collapsed = collapseInterCJKSpaces(text)
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func collapseInterCJKSpaces(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        var result = String.UnicodeScalarView()
        result.reserveCapacity(scalars.count)

        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar == " " {
                // Look at the last emitted scalar and the next non-space one.
                let previous = result.last
                var lookahead = index + 1
                while lookahead < scalars.count, scalars[lookahead] == " " {
                    lookahead += 1
                }
                let next = lookahead < scalars.count ? scalars[lookahead] : nil
                if let previous, let next, isCJK(previous), isCJK(next) {
                    // Drop the whole run of spaces between the two CJK glyphs.
                    index = lookahead
                    continue
                }
            }
            result.append(scalar)
            index += 1
        }
        return String(result)
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF,   // CJK Extension A
             0x4E00...0x9FFF,   // CJK Unified Ideographs
             0xF900...0xFAFF,   // CJK Compatibility Ideographs
             0x3040...0x30FF,   // Hiragana + Katakana
             0x20000...0x2A6DF, // CJK Extension B
             0x3000...0x303F,   // CJK symbols and punctuation (、。「」etc.)
             0xFF00...0xFFEF:   // Fullwidth forms
            return true
        default:
            return false
        }
    }
}
