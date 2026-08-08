import Foundation

/// Infers the smallest useful PDF scope from a natural-language reading request.
/// The UI can still override this with an explicit context choice.
public enum ReadingScopeInference {
    /// A deliberate request to reconstruct code or a formula usually crosses
    /// a printed page boundary. Keep the expansion small and local so the
    /// reader gets the continuation without turning a focused request into a
    /// chapter-wide extraction.
    public static func adjacentPageRange(
        around pageIndex: Int,
        pageCount: Int,
        radius: Int = 1
    ) -> ClosedRange<Int>? {
        guard pageCount > 0, radius >= 0 else { return nil }
        let anchor = min(max(pageIndex, 0), pageCount - 1)
        let start = max(0, anchor - radius)
        let end = min(pageCount - 1, anchor + radius)
        return start...end
    }

    /// Readers often advance with a one- or two-word command instead of a
    /// complete question. Only recognize standalone continuation commands;
    /// phrases such as “继续解释当前页” remain ordinary current-page
    /// questions because they explicitly name what to continue.
    public static func isForwardContinuationRequest(for request: String) -> Bool {
        let normalized = request
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
        return [
            "继续", "继续讲", "继续往下", "继续往下讲", "继续往下看",
            "往下", "往下讲", "往下看"
        ].contains(normalized)
    }

    /// A terse follow-up can inherit a previous range only while the reader is
    /// still looking at that range. This prevents “有多少页” after jumping to
    /// another chapter from silently answering for the old chapter.
    public static func isRecentScopeRelevant(
        _ scope: LearningContextScope,
        turnPageIndex: Int,
        currentPageIndex: Int
    ) -> Bool {
        switch scope {
        case .none:
            return false
        case .page:
            return turnPageIndex == currentPageIndex
        case let .pageRange(start, end):
            return (min(start, end)...max(start, end)).contains(currentPageIndex)
        case .wholeDocument:
            return true
        }
    }

    /// Short metadata questions such as “有多少页” usually refer to the
    /// range the reader just asked about. The UI uses this only when there is
    /// a recent completed turn with a usable scope, so an isolated question
    /// still falls back to the current page.
    public static func inheritsRecentScope(for request: String) -> Bool {
        let normalized = request
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else { return false }
        return [
            "多少页", "几页", "页数", "页码范围",
            "值得看", "值得学", "值得学习", "核心考点", "重点呢", "有什么重点",
            "过时", "还适用", "适用吗", "现在还能", "需要更新",
            // Natural conclusion checks after a chapter/book answer, such as
            // “所以难度不高？” or “所以呢，核心考点？”.
            "所以呢", "所以难度", "所以核心", "所以考点", "所以是不是",
            "那呢", "那么呢", "这样的话", "难度", "对吗", "对么", "真的吗"
        ].contains(where: normalized.contains)
    }

    public static func scope(
        for request: String,
        pageIndex: Int,
        chapterRange: ClosedRange<Int>?,
        sectionRange: ClosedRange<Int>?,
        pageCount: Int? = nil
    ) -> LearningContextScope? {
        let normalized = request
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else { return nil }

        let wholeBookMarkers = ["整本书", "全书", "整本教材", "全教材", "全篇"]
        let bookOverviewMarkers = ["本书", "这本书", "本教材", "这本教材"]
        let overviewQuestionMarkers = [
            "讲什么", "主线", "结构", "概括", "重点", "目录", "章节",
            "难吗", "难不难", "难度", "适合谁", "怎么学", "如何学", "学习路线",
            "过时", "还适用", "适用吗", "需要更新", "现在怎么样", "目前怎么样"
        ]
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

        let previousPageMarkers = [
            "上一页", "前一页", "前面接着", "接着前面", "接着前面的", "承接前面",
            "和前面连起来", "和前面有什么关系", "与前面", "前后关系", "前面讲的",
            "前面内容", "前文", "上文", "上一段", "上面讲的", "刚才", "刚才那页",
            "刚才内容", "接上文", "跟上文", "和上文", "怎么接上", "如何衔接",
            "怎么衔接", "前后怎么联系", "衔接"
        ]
        if pageIndex > 0, previousPageMarkers.contains(where: normalized.contains) {
            return .pageRange(start: pageIndex - 1, end: pageIndex)
        }

        if isForwardContinuationRequest(for: normalized) {
            let nextPage = pageCount.map { min(max(pageIndex + 1, 0), max($0 - 1, 0)) } ?? pageIndex + 1
            return .pageRange(start: min(pageIndex, nextPage), end: max(pageIndex, nextPage))
        }

        let nextPageMarkers = [
            "下一页", "下页", "后面一页", "接下来", "往下讲", "往下看",
            "然后呢", "后面呢", "后面的内容", "后续内容", "再往后"
        ]
        if nextPageMarkers.contains(where: normalized.contains) {
            let nextPage = pageCount.map { min(max(pageIndex + 1, 0), max($0 - 1, 0)) } ?? pageIndex + 1
            return .pageRange(start: min(pageIndex, nextPage), end: max(pageIndex, nextPage))
        }

        return nil
    }
}
