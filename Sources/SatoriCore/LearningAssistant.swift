import Foundation

public enum LearningSourceKind: String, Codable, Sendable {
    case currentPDF
    case relatedMaterial
    case web
    case inference

    public var localizedTitle: String {
        switch self {
        case .currentPDF: "当前 PDF"
        case .relatedMaterial: "关联资料"
        case .web: "网页来源"
        case .inference: "AI 推断"
        }
    }
}

public struct LearningResponse: Sendable, Equatable {
    public var text: String
    public var sourceKind: LearningSourceKind
    public var pageIndex: Int?

    public init(text: String, sourceKind: LearningSourceKind, pageIndex: Int? = nil) {
        self.text = text
        self.sourceKind = sourceKind
        self.pageIndex = pageIndex
    }
}

public protocol LearningAssistant: Sendable {
    func explain(request: String, pageIndex: Int?) async -> LearningResponse
}

public struct UnconfiguredLearningAssistant: LearningAssistant {
    public init() {}

    public func explain(request: String, pageIndex: Int?) async -> LearningResponse {
        LearningResponse(
            text: "AI 理解助手尚未配置 OpenAI API Key。Satori 已保留你的阅读位置；配置后，这里会优先结合当前 PDF 的页码解释问题。",
            sourceKind: .inference,
            pageIndex: pageIndex
        )
    }
}
