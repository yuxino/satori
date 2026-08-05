import Foundation

public enum LearningTurnCompletion: String, Codable, Sendable {
    case completed
    case stopped
}

/// 一轮问答使用的上下文范围；`.pageRange` 的页码为 0 起、含两端。
/// 旧版本存档没有该字段（解码为 nil），按「当前页」处理。
public enum LearningContextScope: Codable, Equatable, Sendable {
    case none
    case page
    case pageRange(start: Int, end: Int)
    case wholeDocument

    private enum Kind: String, Codable {
        case none, page, pageRange, wholeDocument
    }

    private enum CodingKeys: String, CodingKey {
        case kind, start, end
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .none:
            self = .none
        case .page:
            self = .page
        case .pageRange:
            self = .pageRange(
                start: try container.decode(Int.self, forKey: .start),
                end: try container.decode(Int.self, forKey: .end)
            )
        case .wholeDocument:
            self = .wholeDocument
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .none:
            try container.encode(Kind.none, forKey: .kind)
        case .page:
            try container.encode(Kind.page, forKey: .kind)
        case let .pageRange(start, end):
            try container.encode(Kind.pageRange, forKey: .kind)
            try container.encode(start, forKey: .start)
            try container.encode(end, forKey: .end)
        case .wholeDocument:
            try container.encode(Kind.wholeDocument, forKey: .kind)
        }
    }
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
    /// 本轮问答依据的上下文范围；nil 表示旧版本数据，按「当前页」理解。
    public var contextScope: LearningContextScope?
    /// 回答耗时（从发送到完成，秒）；旧版本存档没有该字段（解码为 nil）。
    public var responseDuration: TimeInterval?

    public init(
        id: UUID = UUID(),
        question: String,
        answer: String,
        pageIndex: Int,
        sourceKind: LearningSourceKind,
        citations: [LearningCitation] = [],
        attachmentCount: Int = 0,
        createdAt: Date = .now,
        completion: LearningTurnCompletion = .completed,
        contextScope: LearningContextScope? = nil,
        responseDuration: TimeInterval? = nil
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
        self.contextScope = contextScope
        self.responseDuration = responseDuration
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
