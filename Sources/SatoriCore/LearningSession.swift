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
    /// 该轮问答依据的页码（0 起）；为 nil 表示没有锚定到具体页。
    public var pageIndex: Int?
    /// 附件摘要（例如「2 张附图：示意图、公式截图」）；为 nil 表示没有附图。
    public var attachmentSummary: String?

    public init(
        question: String,
        answer: String,
        pageIndex: Int? = nil,
        attachmentSummary: String? = nil
    ) {
        self.question = question
        self.answer = answer
        self.pageIndex = pageIndex
        self.attachmentSummary = attachmentSummary
    }
}
