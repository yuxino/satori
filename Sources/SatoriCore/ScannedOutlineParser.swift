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
            guard let chapterNumber = ChapterNumberParser.number(in: chapterToken),
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

}
