import Foundation

/// A top-level chapter recovered from a scanned table of contents.
/// `printedPage` is the page number visible in the book, not the PDF index.
public struct ScannedOutlineEntry: Equatable, Sendable {
    public let chapterNumber: Int
    public let title: String
    public let printedPage: Int
    /// Section number when this is a depth-1 entry; nil for a chapter.
    public let sectionNumber: Int?
    /// 0 = chapter, 1 = section. The parser intentionally stops here because
    /// deeper OCR hierarchy is too noisy for navigation.
    public let depth: Int

    public init(
        chapterNumber: Int,
        title: String,
        printedPage: Int,
        sectionNumber: Int? = nil,
        depth: Int = 0
    ) {
        self.chapterNumber = chapterNumber
        self.title = title
        self.printedPage = printedPage
        self.sectionNumber = sectionNumber
        self.depth = depth
    }
}

/// Parses the compact, noisy lines commonly produced by OCR over a Chinese
/// table of contents. The compatibility `parse` API returns numbered
/// top-level chapters; `parseHierarchy` also preserves first-level sections.
public enum ScannedOutlineParser {
    public static func parse(lines: [String]) -> [ScannedOutlineEntry] {
        var seen = Set<Int>()
        return parseHierarchy(lines: lines)
            .filter { $0.depth == 0 }
            .sorted { lhs, rhs in
                if lhs.printedPage == rhs.printedPage {
                    return lhs.chapterNumber < rhs.chapterNumber
                }
                return lhs.printedPage < rhs.printedPage
            }
            .filter { seen.insert($0.chapterNumber).inserted }
    }

    /// Parses chapters and their first-level sections from noisy OCR lines.
    /// Section titles occasionally wrap before the printed page number, so a
    /// pending heading is allowed to consume the following line.
    public static func parseHierarchy(lines: [String]) -> [ScannedOutlineEntry] {
        var result: [ScannedOutlineEntry] = []
        var currentChapterNumber: Int?
        var pending: PendingHeading?

        for line in lines {
            let compact = compacted(line)
            guard !compact.isEmpty else { continue }

            if let marker = marker(in: compact) {
                pending = nil
                currentChapterNumber = marker.depth == 0 ? marker.number : currentChapterNumber
                if let entry = parse(compact, marker: marker, chapterNumber: currentChapterNumber) {
                    result.append(entry)
                } else {
                    pending = PendingHeading(marker: marker, title: marker.suffix)
                }
                continue
            }

            guard let waiting = pending else { continue }
            let combinedTitle = waiting.title + compact
            let combined = waiting.marker.token + combinedTitle
            if let entry = parse(
                combined,
                marker: waiting.marker,
                chapterNumber: currentChapterNumber
            ) {
                result.append(entry)
                pending = nil
            }
        }

        return result
            .sorted { lhs, rhs in
                if lhs.printedPage == rhs.printedPage {
                    if lhs.chapterNumber == rhs.chapterNumber {
                        return lhs.depth < rhs.depth
                    }
                    return lhs.chapterNumber < rhs.chapterNumber
                }
                return lhs.printedPage < rhs.printedPage
            }
    }

    private struct Marker {
        let token: String
        let number: Int
        let depth: Int
        let suffix: String
    }

    private struct PendingHeading {
        let marker: Marker
        let title: String
    }

    private static func marker(in compact: String) -> Marker? {
        guard let range = compact.range(
            of: #"^第[0-9一二三四五六七八九十百零〇两]+[章节]"#,
            options: .regularExpression
        ) else { return nil }
        let token = String(compact[range])
        let depth = token.hasSuffix("章") ? 0 : 1
        guard let number = ChapterNumberParser.number(in: token, unit: token.last ?? "章") else { return nil }
        return Marker(
            token: token,
            number: number,
            depth: depth,
            suffix: String(compact[range.upperBound...])
        )
    }

    private static func parse(
        _ compact: String,
        marker: Marker,
        chapterNumber: Int?
    ) -> ScannedOutlineEntry? {
        let effectiveChapterNumber = marker.depth == 0 ? marker.number : chapterNumber
        guard let effectiveChapterNumber,
              let pageRange = compact.range(of: #"[0-9]{1,4}$"#, options: .regularExpression),
              let printedPage = Int(compact[pageRange]),
              printedPage > 0 else { return nil }

        var title = String(compact[marker.token.endIndex..<pageRange.lowerBound])
        title = title.trimmingCharacters(in: CharacterSet(charactersIn: ".·•…—–-:：_"))
        guard !title.isEmpty else { return nil }
        return ScannedOutlineEntry(
            chapterNumber: effectiveChapterNumber,
            title: title,
            printedPage: printedPage,
            sectionNumber: marker.depth == 1 ? marker.number : nil,
            depth: marker.depth
        )
    }

    private static func compacted(_ line: String) -> String {
        line
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
            .replacingOccurrences(of: "．", with: ".")
    }

}
