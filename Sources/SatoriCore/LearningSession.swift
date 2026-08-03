import Foundation

public enum LearningTurnCompletion: String, Codable, Sendable {
    case completed
    case stopped
}

public struct LearningTurn: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var question: String
    public var answer: String
    public var pageIndex: Int
    public var sourceKind: LearningSourceKind
    public var citations: [LearningCitation]
    public var attachmentCount: Int
    public var createdAt: Date
    public var completion: LearningTurnCompletion

    public init(
        id: UUID = UUID(),
        question: String,
        answer: String,
        pageIndex: Int,
        sourceKind: LearningSourceKind,
        citations: [LearningCitation] = [],
        attachmentCount: Int = 0,
        createdAt: Date = .now,
        completion: LearningTurnCompletion = .completed
    ) {
        self.id = id
        self.question = question
        self.answer = answer
        self.pageIndex = max(0, pageIndex)
        self.sourceKind = sourceKind
        self.citations = citations
        self.attachmentCount = max(0, attachmentCount)
        self.createdAt = Date(timeIntervalSince1970: floor(createdAt.timeIntervalSince1970))
        self.completion = completion
    }
}

public struct LearningConversationContext: Sendable, Equatable {
    public var question: String
    public var answer: String

    public init(question: String, answer: String) {
        self.question = question
        self.answer = answer
    }
}
