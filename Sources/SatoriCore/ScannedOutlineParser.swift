import Foundation

/// A top-level chapter recovered from a scanned table of contents.
/// `printedPage` is the page number visible in the book, not the PDF index.
public struct ScannedOutlineEntry: Equatable, Sendable {
    public let chapterNumber: Int
    public let title: String
    public let printedPage: Int

    public init(chapterNumber: Int, title: String, printedPage: Int) {
        self.chapterNumber = chapterNumber
        self.title = title
        self.printedPage = printedPage
    }
}

/// Parses the compact, noisy lines commonly produced by OCR over a Chinese
/// table of contents. It deliberately extracts only numbered top-level
/// chapters; sections are left to the page-level reader until the PDF exposes
/// stronger evidence.
public enum ScannedOutlineParser {
    public static func parse(lines: [String]) -> [ScannedOutlineEntry] {
        var result: [ScannedOutlineEntry] = []

        for line in lines {
            let compact = compacted(line)
            guard let chapterRange = compact.range(
                of: #"^第[0-9一二三四五六七八九十百零〇两]+章"#,
                options: .regularExpression
            ) else { continue }

            let chapterToken = String(compact[chapterRange])
            let numberToken = chapterToken
                .replacingOccurrences(of: "第", with: "")
                .replacingOccurrences(of: "章", with: "")
            guard let chapterNumber = parseNumber(numberToken), chapterNumber > 0,
                  let pageRange = compact.range(of: #"[0-9]{1,4}$"#, options: .regularExpression),
                  let printedPage = Int(compact[pageRange]), printedPage > 0 else {
                continue
            }

            var title = String(compact[chapterRange.upperBound..<pageRange.lowerBound])
            title = title.trimmingCharacters(in: CharacterSet(charactersIn: ".·•…—–-:：_"))
            guard !title.isEmpty else { continue }

            result.append(
                ScannedOutlineEntry(
                    chapterNumber: chapterNumber,
                    title: title,
                    printedPage: printedPage
                )
            )
        }

        var seen = Set<Int>()
        return result
            .sorted { lhs, rhs in
                if lhs.printedPage == rhs.printedPage {
                    return lhs.chapterNumber < rhs.chapterNumber
                }
                return lhs.printedPage < rhs.printedPage
            }
            .filter { seen.insert($0.chapterNumber).inserted }
    }

    private static func compacted(_ line: String) -> String {
        line
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
            .replacingOccurrences(of: "．", with: ".")
    }

    private static func parseNumber(_ token: String) -> Int? {
        if let arabic = Int(token) { return arabic }
        let values: [Character: Int] = [
            "零": 0, "〇": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4,
            "五": 5, "六": 6, "七": 7, "八": 8, "九": 9, "十": 10, "百": 100
        ]
        var total = 0
        var section = 0
        var current = 0
        for character in token {
            guard let value = values[character] else { return nil }
            if value == 10 || value == 100 {
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
