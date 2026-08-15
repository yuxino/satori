import Foundation

/// Separates real learning chapters from the top-level front matter that many
/// textbook outlines expose as siblings: cover, foreword, contents, exam
/// outline, and only then “第一章 …”.
public enum ReadingChapterSelector {
    public static func isNumberedChapterTitle(_ title: String) -> Bool {
        let compact = title.replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
        if ChapterNumberParser.number(in: compact) != nil { return true }
        let normalized = title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalized.range(
            of: #"^chapter\s+\d+"#,
            options: .regularExpression
        ) != nil
    }

    /// Returns the original-array index of the first real chapter. If an
    /// outline has no numbered chapters (for example a user-created reading
    /// directory), its first top-level item remains the safe fallback.
    public static func firstRealChapterIndex(
        titles: [String],
        depths: [Int]
    ) -> Int? {
        guard titles.count == depths.count else { return nil }
        let topLevelIndices = titles.indices.filter { depths[$0] == 0 }
        guard !topLevelIndices.isEmpty else { return nil }
        let hasNumberedChapter = topLevelIndices.contains {
            isNumberedChapterTitle(titles[$0])
        }
        return topLevelIndices.first {
            !hasNumberedChapter || isNumberedChapterTitle(titles[$0])
        }
    }
}
