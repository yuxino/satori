import Foundation

/// Answers deterministic reading metadata without spending a model request.
/// This is deliberately small: it handles facts the reader already knows and
/// leaves interpretation, explanation, and comparison to the learning model.
public enum ReadingFactAnswer {
    public static func pageCountAnswer(
        for request: String,
        pageCount: Int,
        currentPageIndex: Int,
        scope: LearningContextScope,
        chapterRange: ClosedRange<Int>? = nil
    ) -> String? {
        let normalized = request
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard pageCount > 0,
              ["多少页", "几页", "页数", "页码范围"].contains(where: normalized.contains) else {
            return nil
        }

        let range: ClosedRange<Int>?
        if normalized.contains("本书") || normalized.contains("全书") || normalized.contains("整本") {
            range = 0...(pageCount - 1)
        } else if ReadingScopeInference.referencesChapter(in: normalized) {
            // A chapter question with unknown chapter boundaries is not a
            // one-page question. Returning nil lets the UI wait for scanned
            // outline recovery or ask the reader to choose an explicit range.
            guard let chapterRange else { return nil }
            range = clamped(chapterRange, pageCount: pageCount)
        } else {
            switch scope {
            case .none:
                range = nil
            case .page:
                let current = min(max(currentPageIndex, 0), pageCount - 1)
                range = current...current
            case let .pageRange(start, end):
                let lower = min(max(start, 0), pageCount - 1)
                let upper = min(max(end, 0), pageCount - 1)
                range = min(lower, upper)...max(lower, upper)
            case .wholeDocument:
                range = 0...(pageCount - 1)
            }
        }

        guard let range else { return nil }
        let count = range.count
        if count == 1 {
            return "当前范围是第 \(range.lowerBound + 1) 页，共 1 页。"
        }
        return "当前范围是第 \(range.lowerBound + 1)–\(range.upperBound + 1) 页，共 \(count) 页。"
    }

    private static func clamped(_ range: ClosedRange<Int>, pageCount: Int) -> ClosedRange<Int> {
        let lower = min(max(range.lowerBound, 0), pageCount - 1)
        let upper = min(max(range.upperBound, 0), pageCount - 1)
        return min(lower, upper)...max(lower, upper)
    }
}
