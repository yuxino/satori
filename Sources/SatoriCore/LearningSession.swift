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
    /// 用户发起本轮问答时主动选中的原文；旧版本存档没有该字段。
    /// 保存它是为了让「重试」和回看笔记时仍然围绕同一段内容回答。
    public var selectionText: String?
    /// 选中原文时的页内阅读偏移（0…1）；旧版本存档没有该字段。
    /// 让「回到原文」和重试能够回到句子附近，而不是只回到页首。
    public var selectionOffset: Double?

    private enum CodingKeys: String, CodingKey {
        case id, question, answer, pageIndex, sourceKind, citations, attachmentCount
        case createdAt, completion, contextScope, responseDuration
        case selectionText, selectionOffset
    }

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
        responseDuration: TimeInterval? = nil,
        selectionText: String? = nil,
        selectionOffset: Double? = nil
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
        self.selectionText = selectionText?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.selectionOffset = selectionOffset.map { min(max($0, 0), 1) }
    }

    /// Decode through the same normalization as newly-created turns. This is
    /// important for old or hand-edited archives: synthesized Codable would
    /// bypass the page/offset clamps in the initializer.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            question: try container.decode(String.self, forKey: .question),
            answer: try container.decode(String.self, forKey: .answer),
            pageIndex: try container.decode(Int.self, forKey: .pageIndex),
            sourceKind: try container.decode(LearningSourceKind.self, forKey: .sourceKind),
            citations: try container.decode([LearningCitation].self, forKey: .citations),
            attachmentCount: try container.decode(Int.self, forKey: .attachmentCount),
            createdAt: try container.decode(Date.self, forKey: .createdAt),
            completion: try container.decode(LearningTurnCompletion.self, forKey: .completion),
            contextScope: try container.decodeIfPresent(LearningContextScope.self, forKey: .contextScope),
            responseDuration: try container.decodeIfPresent(TimeInterval.self, forKey: .responseDuration),
            selectionText: try container.decodeIfPresent(String.self, forKey: .selectionText),
            selectionOffset: try container.decodeIfPresent(Double.self, forKey: .selectionOffset)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(question, forKey: .question)
        try container.encode(answer, forKey: .answer)
        try container.encode(pageIndex, forKey: .pageIndex)
        try container.encode(sourceKind, forKey: .sourceKind)
        try container.encode(citations, forKey: .citations)
        try container.encode(attachmentCount, forKey: .attachmentCount)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(completion, forKey: .completion)
        try container.encodeIfPresent(contextScope, forKey: .contextScope)
        try container.encodeIfPresent(responseDuration, forKey: .responseDuration)
        try container.encodeIfPresent(selectionText, forKey: .selectionText)
        try container.encodeIfPresent(selectionOffset, forKey: .selectionOffset)
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
