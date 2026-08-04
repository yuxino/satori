import Foundation

/// Gamification state for the whole app — visible progress so studying feels
/// like moving forward instead of endless reading. Tracks per-book progress,
/// a daily streak, and milestones unlocked by real behavior.
public struct LearningStats: Codable, Equatable, Sendable {
    // Per-document activity counts (real behaviors → progress).
    public var documentCounts: [UUID: DocumentActivity]
    // When the user last "studied" (opened a book + did one real action).
    public var lastActiveDay: Date?
    public var streakDays: Int
    public var longestStreak: Int
    public var unlockedBadges: Set<BadgeID>

    public init(
        documentCounts: [UUID: DocumentActivity] = [:],
        lastActiveDay: Date? = nil,
        streakDays: Int = 0,
        longestStreak: Int = 0,
        unlockedBadges: Set<BadgeID> = []
    ) {
        self.documentCounts = documentCounts
        self.lastActiveDay = lastActiveDay
        self.streakDays = streakDays
        self.longestStreak = longestStreak
        self.unlockedBadges = unlockedBadges
    }

    public struct DocumentActivity: Codable, Equatable, Sendable {
        public var pagesRead: Set<Int>
        public var questionsAsked: Int
        public var codeRuns: Int
        public var pageCount: Int

        public init(pagesRead: Set<Int> = [], questionsAsked: Int = 0, codeRuns: Int = 0, pageCount: Int = 0) {
            self.pagesRead = pagesRead
            self.questionsAsked = questionsAsked
            self.codeRuns = codeRuns
            self.pageCount = pageCount
        }

        public var progress: Double {
            guard pageCount > 0 else { return 0 }
            return min(Double(pagesRead.count) / Double(pageCount), 1)
        }
    }
}

/// Badges unlocked by behavior milestones. Their order defines unlock order.
public enum BadgeID: String, Codable, CaseIterable, Sendable {
    case firstQuestion     // 第一次提问
    case tenQuestions      // 累计问过 10 个问题
    case firstCodeRun      // 第一次运行代码
    case tenCodeRuns       // 累计运行 10 段代码
    case threeDayStreak    // 连续学习 3 天
    case sevenDayStreak    // 连续学习 7 天
    case firstBook         // 第一本书读完 100%

    public var title: String {
        switch self {
        case .firstQuestion: "开了头"
        case .tenQuestions: "勤学好问"
        case .firstCodeRun: "动起手来"
        case .tenCodeRuns: "动手达人"
        case .threeDayStreak: "坚持三天"
        case .sevenDayStreak: "坚持一周"
        case .firstBook: "读完第一本"
        }
    }

    public var systemImage: String {
        switch self {
        case .firstQuestion: "questionmark.bubble"
        case .tenQuestions: "questionmark.bubble.fill"
        case .firstCodeRun: "play.rectangle"
        case .tenCodeRuns: "play.rectangle.fill"
        case .threeDayStreak: "flame"
        case .sevenDayStreak: "flame.fill"
        case .firstBook: "books.vertical.fill"
        }
    }
}
