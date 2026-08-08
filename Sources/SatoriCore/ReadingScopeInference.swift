import Foundation

/// Infers the smallest useful PDF scope from a natural-language reading request.
/// The UI can still override this with an explicit context choice.
public enum ReadingScopeInference {
    public static func scope(
        for request: String,
        pageIndex: Int,
        chapterRange: ClosedRange<Int>?,
        sectionRange: ClosedRange<Int>?
    ) -> LearningContextScope? {
        let normalized = request
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else { return nil }

        let wholeBookMarkers = ["整本书", "全书", "整本教材", "全教材", "全篇"]
        let bookOverviewMarkers = ["本书", "这本书", "本教材", "这本教材"]
        let overviewQuestionMarkers = ["讲什么", "主线", "结构", "概括", "重点", "目录", "章节"]
        if wholeBookMarkers.contains(where: normalized.contains)
            || (bookOverviewMarkers.contains(where: normalized.contains)
                && overviewQuestionMarkers.contains(where: normalized.contains)) {
            return .wholeDocument
        }

        let chapterMarkers = ["这一章", "这章", "本章", "这个章节", "该章节", "当前章节", "整章"]
        let numberedChapter = normalized.range(
            of: #"第[0-9一二三四五六七八九十百]+章"#,
            options: .regularExpression
        ) != nil
        if (chapterMarkers.contains(where: normalized.contains) || numberedChapter),
           let chapterRange {
            return .pageRange(start: chapterRange.lowerBound, end: chapterRange.upperBound)
        }

        let sectionMarkers = ["这一节", "本节", "这节", "当前小节", "该小节"]
        if sectionMarkers.contains(where: normalized.contains),
           let sectionRange {
            return .pageRange(start: sectionRange.lowerBound, end: sectionRange.upperBound)
        }

        let previousPageMarkers = ["上一页", "前一页", "前面接着", "接着前面", "承接前面", "和前面连起来"]
        if pageIndex > 0, previousPageMarkers.contains(where: normalized.contains) {
            return .pageRange(start: pageIndex - 1, end: pageIndex)
        }

        return nil
    }
}
