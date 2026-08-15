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
        /// How many review ratings this document has received.
        public var reviewsCompleted: Int
        /// Accumulated recall quality (good 1.0 / hard 0.5 / again 0.0).
        public var masteryScore: Double

        public init(
            pagesRead: Set<Int> = [],
            questionsAsked: Int = 0,
            codeRuns: Int = 0,
            pageCount: Int = 0,
            reviewsCompleted: Int = 0,
            masteryScore: Double = 0
        ) {
            self.pagesRead = pagesRead
            self.questionsAsked = questionsAsked
            self.codeRuns = codeRuns
            self.pageCount = pageCount
            self.reviewsCompleted = reviewsCompleted
            self.masteryScore = masteryScore
        }

        /// Fraction of reviews recalled well; 0 until the first review.
        public var reviewMastery: Double {
            guard reviewsCompleted > 0 else { return 0 }
            return min(masteryScore / Double(reviewsCompleted), 1)
        }

        /// Reading coverage: distinct pages read over the book's page count.
        public var progress: Double {
            guard pageCount > 0 else { return 0 }
            return min(Double(pagesRead.count) / Double(pageCount), 1)
        }

        /// Mastery-based progress = reading coverage × review mastery, so
        /// merely flipping pages never reads as "learned".
        public var masteredProgress: Double {
            progress * reviewMastery
        }

        private enum CodingKeys: String, CodingKey {
            case pagesRead
            case questionsAsked
            case codeRuns
            case pageCount
            case reviewsCompleted
            case masteryScore
        }

        // Custom decoding keeps archives written before the review fields
        // existed decodable: missing keys fall back to their defaults.
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            pagesRead = try container.decode(Set<Int>.self, forKey: .pagesRead)
            questionsAsked = try container.decodeIfPresent(Int.self, forKey: .questionsAsked) ?? 0
            codeRuns = try container.decodeIfPresent(Int.self, forKey: .codeRuns) ?? 0
            pageCount = try container.decodeIfPresent(Int.self, forKey: .pageCount) ?? 0
            reviewsCompleted = try container.decodeIfPresent(Int.self, forKey: .reviewsCompleted) ?? 0
            masteryScore = try container.decodeIfPresent(Double.self, forKey: .masteryScore) ?? 0
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
