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

    public init(
        id: UUID = UUID(),
        question: String,
        answer: String,
        pageIndex: Int,
        createdAt: Date = .now,
        dueAt: Date = .now,
        reviewCount: Int = 0,
        lastRating: ReviewRating? = nil
    ) {
        self.id = id
        self.question = question
        self.answer = answer
        self.pageIndex = max(0, pageIndex)
        self.createdAt = createdAt
        self.dueAt = dueAt
        self.reviewCount = max(0, reviewCount)
        self.lastRating = lastRating
    }
}
