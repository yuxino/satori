import Foundation

/// Reads a numbered chapter marker in either Arabic or Chinese form.
/// Scanned OCR and native PDF outlines often disagree on the representation
/// (`第6章` vs `第六章`), but a reader expects them to refer to the same place.
public enum ChapterNumberParser {
    public static func number(in text: String) -> Int? {
        guard let range = text.range(
            of: #"第[0-9一二三四五六七八九十百千万零〇两]+章"#,
            options: .regularExpression
        ) else { return nil }

        return number(inMarker: String(text[range]), unit: "章")
    }

    /// Reads the same Chinese/Arabic number when the marker is a first-level
    /// section such as “第一节”. Keeping it here avoids a second, subtly
    /// different Chinese-number implementation in scanned-outline parsing.
    public static func number(in text: String, unit: Character) -> Int? {
        guard let range = text.range(
            of: #"第[0-9一二三四五六七八九十百千万零〇两]+[章节]"#,
            options: .regularExpression
        ) else { return nil }
        let marker = String(text[range])
        guard marker.last == unit else { return nil }
        return number(inMarker: marker, unit: String(unit))
    }

    private static func number(inMarker marker: String, unit: String) -> Int? {
        let token = marker
            .replacingOccurrences(of: "第", with: "")
            .replacingOccurrences(of: unit, with: "")
        if let arabic = Int(token) {
            return arabic > 0 ? arabic : nil
        }

        let values: [Character: Int] = [
            "零": 0, "〇": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4,
            "五": 5, "六": 6, "七": 7, "八": 8, "九": 9, "十": 10,
            "百": 100, "千": 1_000, "万": 10_000
        ]
        var total = 0
        var section = 0
        var current = 0
        for character in token {
            guard let value = values[character] else { return nil }
            if value == 10 || value == 100 || value == 1_000 || value == 10_000 {
                section += (current == 0 ? 1 : current) * value
                current = 0
            } else {
                current = value
            }
        }
        total += section + current
        return total > 0 ? total : nil
    }
}
