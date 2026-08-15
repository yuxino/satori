import Foundation

/// How well a review question was recalled. Drives the spacing schedule so a
/// question returns sooner when it was hard and later once it's easy.
public enum ReviewRating: String, Codable, Sendable, CaseIterable {
    case again  // 生疏 — couldn't recall
    case hard   // 还行 — recalled with effort
    case good   // 记住了 — recalled easily

    public var localizedTitle: String {
        switch self {
        case .again: "生疏"
        case .hard: "还行"
        case .good: "记住了"
        }
    }

    /// Contribution to a document's review mastery (0…1 per rating).
    public var masteryWeight: Double {
        switch self {
        case .good: 1.0
        case .hard: 0.5
        case .again: 0.0
        }
    }
}

/// A single retrieval-practice question generated from what the reader read
/// and asked. Scheduling is driven by `dueAt`: a question is "due" for review
/// once its date has passed, and rating it pushes `dueAt` into the future.
public struct ReviewQuestion: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var question: String
    public var answer: String
    public var pageIndex: Int
    public var createdAt: Date
    public var dueAt: Date
    public var reviewCount: Int
    public var lastRating: ReviewRating?
    /// How many times in a row this question was rated "记住了" (good). SM-2
    /// uses this streak to grow the next interval: 1, 2, 4, 8… days.
    public var consecutiveGoodCount: Int
    /// Interval (in days) chosen by the last rating; 0 before any rating.
    public var lastIntervalDays: Double

    public init(
        id: UUID = UUID(),
        question: String,
        answer: String,
        pageIndex: Int,
        createdAt: Date = .now,
        dueAt: Date = .now,
        reviewCount: Int = 0,
        lastRating: ReviewRating? = nil,
        consecutiveGoodCount: Int = 0,
        lastIntervalDays: Double = 0
    ) {
        self.id = id
        self.question = question
        self.answer = answer
        self.pageIndex = max(0, pageIndex)
        self.createdAt = createdAt
        self.dueAt = dueAt
        self.reviewCount = max(0, reviewCount)
        self.lastRating = lastRating
        self.consecutiveGoodCount = max(0, consecutiveGoodCount)
        self.lastIntervalDays = max(0, lastIntervalDays)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case question
        case answer
        case pageIndex
        case createdAt
        case dueAt
        case reviewCount
        case lastRating
        case consecutiveGoodCount
        case lastIntervalDays
    }

    // Custom decoding keeps archives written before the SM-2 fields existed
    // decodable: missing keys fall back to their defaults.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        question = try container.decode(String.self, forKey: .question)
        answer = try container.decode(String.self, forKey: .answer)
        pageIndex = try container.decode(Int.self, forKey: .pageIndex)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        dueAt = try container.decode(Date.self, forKey: .dueAt)
        reviewCount = try container.decodeIfPresent(Int.self, forKey: .reviewCount) ?? 0
        lastRating = try container.decodeIfPresent(ReviewRating.self, forKey: .lastRating)
        consecutiveGoodCount = try container.decodeIfPresent(Int.self, forKey: .consecutiveGoodCount) ?? 0
        lastIntervalDays = try container.decodeIfPresent(Double.self, forKey: .lastIntervalDays) ?? 0
    }
}
