import Foundation

/// Chooses only the saved reading turns that can help answer the current
/// request. Conversation history is a bridge between nearby pages, not a
/// second textbook that should follow the reader forever.
public enum ReadingConversationContextSelector {
    public static func select(
        turns: [LearningTurn],
        targetPageIndex: Int,
        scope: LearningContextScope,
        excludingTurnID: UUID? = nil,
        maximumCount: Int = 6
    ) -> [LearningTurn] {
        guard maximumCount > 0 else { return [] }

        let candidates = turns.filter { turn in
            guard turn.id != excludingTurnID else { return false }
            return hasConsistentAnchor(turn)
        }

        switch scope {
        case .none:
            // “不带上下文” is an intentional request boundary. Do not let
            // an old answer sneak back in through the conversation history.
            return []

        case .page:
            // A one-page question may still be the next step after the page
            // just read. Keep only the local bridge, never an old chapter.
            return newest(
                candidates.filter { abs($0.pageIndex - targetPageIndex) <= 1 },
                maximumCount: maximumCount
            )

        case let .pageRange(start, end):
            let lower = min(start, end)
            let upper = max(start, end)
            let range = lower...upper

            // Short bridges such as “接上文” should carry the turns from
            // exactly those pages. A broad chapter map should instead carry
            // only an earlier broad map, not every local selection explanation
            // that happened to occur inside the chapter.
            if upper - lower <= 2 {
                return newest(
                    candidates.filter { range.contains($0.pageIndex) },
                    maximumCount: maximumCount
                )
            }

            let broad = candidates.filter { turn in
                guard let savedScope = turn.contextScope else { return false }
                guard rangeCoversPage(savedScope, targetPageIndex) else { return false }
                switch savedScope {
                case .wholeDocument:
                    return true
                case let .pageRange(savedStart, savedEnd):
                    return abs(savedEnd - savedStart) >= 3
                case .none, .page:
                    return false
                }
            }
            if !broad.isEmpty {
                return newest(broad, maximumCount: maximumCount)
            }

            // If there is no prior map, keep a tiny local foothold rather than
            // importing unrelated pages just because the requested range is
            // large.
            return newest(
                candidates.filter { abs($0.pageIndex - targetPageIndex) <= 1 },
                maximumCount: maximumCount
            )

        case .wholeDocument:
            let broad = candidates.filter { turn in
                guard let savedScope = turn.contextScope else { return false }
                switch savedScope {
                case .wholeDocument:
                    return true
                case let .pageRange(start, end):
                    return abs(end - start) >= 3
                case .none, .page:
                    return false
                }
            }
            if !broad.isEmpty {
                return newest(broad, maximumCount: maximumCount)
            }
            return newest(
                candidates.filter { abs($0.pageIndex - targetPageIndex) <= 1 },
                maximumCount: maximumCount
            )
        }
    }

    public static func hasConsistentAnchor(_ turn: LearningTurn) -> Bool {
        guard let scope = turn.contextScope else {
            // Legacy turns had no saved scope; their page anchor is the only
            // trustworthy location we have, so keep them for nearby questions.
            return true
        }
        switch scope {
        case .none, .page, .wholeDocument:
            return true
        case let .pageRange(start, end):
            return (min(start, end)...max(start, end)).contains(turn.pageIndex)
        }
    }

    private static func rangeCoversPage(
        _ scope: LearningContextScope,
        _ pageIndex: Int
    ) -> Bool {
        switch scope {
        case .none, .page:
            return false
        case let .pageRange(start, end):
            return (min(start, end)...max(start, end)).contains(pageIndex)
        case .wholeDocument:
            return true
        }
    }

    private static func newest(
        _ turns: [LearningTurn],
        maximumCount: Int
    ) -> [LearningTurn] {
        Array(turns.suffix(maximumCount))
    }
}
