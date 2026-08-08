import CoreGraphics
import Foundation
import ImageIO

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

    /// 持久化值未知（旧版本/未来新增 case）时回退到 .inference，
    /// 避免学习记录存档整体解码失败。
    public init(from decoder: Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(String.self)
        self = LearningSourceKind(rawValue: rawValue) ?? .inference
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct LearningResponse: Sendable, Equatable {
    public var text: String
    public var sourceKind: LearningSourceKind
    public var pageIndex: Int?
    public var citations: [LearningCitation]
    /// 回答因达到输出上限等原因被截断（SSE response.incomplete）。
    public var isTruncated: Bool
    /// 本次请求失败时的可读中文错误；正常回答为 nil。
    public var errorMessage: String?
    /// 附图因体积/数量超限被压缩或丢弃时的提示；没有处理时为 nil。
    public var attachmentNotice: String?

    public init(
        text: String,
        sourceKind: LearningSourceKind,
        pageIndex: Int? = nil,
        citations: [LearningCitation] = [],
        isTruncated: Bool = false,
        errorMessage: String? = nil,
        attachmentNotice: String? = nil
    ) {
        self.text = text
        self.sourceKind = sourceKind
        self.pageIndex = pageIndex
        self.citations = citations
        self.isTruncated = isTruncated
        self.errorMessage = errorMessage
        self.attachmentNotice = attachmentNotice
    }
}

public struct LearningCitation: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public var title: String
    public var url: URL

    public init(id: UUID = UUID(), title: String, url: URL) {
        self.id = id
        self.title = title
        self.url = url
    }
}

/// A page image that supplements a reliable text layer when a PDF page's
/// meaning depends on a diagram, table, or other visual structure.
public struct LearningPageImage: Sendable, Equatable {
    public let pageIndex: Int
    public let jpegData: Data

    public init(pageIndex: Int, jpegData: Data) {
        self.pageIndex = max(0, pageIndex)
        self.jpegData = jpegData
    }
}

public enum LearningPageContent: Sendable, Equatable {
    case text(String)
    case imageJPEG(Data)
    /// A mostly useful text layer with enough OCR damage that the page image
    /// should be sent too, so the model can verify names, numbers, and symbols.
    case textAndImage(String, Data)
    /// A reliable text layer plus one or more page images for visual evidence.
    /// This is used for short page bridges; long chapter maps remain text-only
    /// so the first answer stays fast and within a small image budget.
    case textAndImages(String, [LearningPageImage])
}

public struct AssistantTransportResponse: Sendable {
    public let data: Data
    public let statusCode: Int

    public init(data: Data, statusCode: Int) {
        self.data = data
        self.statusCode = statusCode
    }
}

public protocol AssistantTransport: Sendable {
    func send(_ request: URLRequest) async throws -> AssistantTransportResponse
    func stream(_ request: URLRequest) -> AsyncThrowingStream<Data, Error>
}

public protocol LearningAssistant: Sendable {
    func explain(request: String, pageIndex: Int?) async -> LearningResponse
}

public struct UnconfiguredLearningAssistant: LearningAssistant {
    public init() {}

    public func explain(request: String, pageIndex: Int?) async -> LearningResponse {
        LearningResponse(
            text: "AI 理解助手尚未配置百炼 API Key。Satori 已保留你的阅读位置；配置后，这里会优先结合当前 PDF 的页码解释问题。",
            sourceKind: .inference,
            pageIndex: pageIndex
        )
    }
}

/// 模型能力维度。请求前用 `QwenLearningAssistant.capabilities(for:)`
/// 校验，图片页/联网不可用时给出可读错误，而不是静默失败。
public enum ModelCapability: String, CaseIterable, Codable, Sendable {
    case text
    case image
    case webSearch

    public var localizedTitle: String {
        switch self {
        case .text: "文字"
        case .image: "图片"
        case .webSearch: "联网搜索"
        }
    }
}

/// 结构化错误：失败时抛给调用方，UI 可直接展示 `localizedDescription`。
public enum AssistantError: LocalizedError, Sendable, Equatable {
    case invalidResponse
    case emptyOutput
    case timeout
    case api(statusCode: Int?, message: String)
    case capabilityUnavailable(capability: ModelCapability, modelID: String)
    case reviewParsing(skippedLines: Int)
    case reviewPageUnclear

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "百炼返回了无法识别的响应。"
        case .emptyOutput:
            "Qwen 没有返回可显示的文字。可能是选中的 PDF 文字过长或识别异常，请缩短选区后重试。"
        case .timeout:
            "回答超时（长时间没有新内容），请重试。"
        case let .api(statusCode, message):
            if let statusCode {
                "百炼请求失败（HTTP \(statusCode)）：\(message)"
            } else {
                message
            }
        case let .capabilityUnavailable(capability, modelID):
            switch capability {
            case .image:
                "当前模型（\(modelID)）不支持图片输入，无法分析扫描页或附图。请在设置中切换到 qwen3.8-max 或 qwen3.7-plus。"
            case .webSearch:
                "当前模型（\(modelID)）不支持联网搜索。请在设置中切换到 qwen3.8-max 或 qwen3.7-plus。"
            case .text:
                "当前模型（\(modelID)）不支持文字输入。"
            }
        case let .reviewParsing(skippedLines):
            "AI 返回的复习题无法解析（有 \(skippedLines) 行不符合“问题 | 答案”格式）。请重试。"
        case .reviewPageUnclear:
            "AI 没能看清页面内容，因此没有编造题目。请重试，或换用文字版 PDF。"
        }
    }
}

public struct QwenLearningAssistant: LearningAssistant {
    public static let defaultModelID = "qwen3.8-max"
    public static let defaultAPIHost = URL(string: "https://dashscope.aliyuncs.com/compatible-mode/v1")!
    /// 流式回答的总超时：连接挂起（既不返回数据也不结束）时强制结束，
    /// 避免界面永远停在等待状态、只能重启应用。
    public static let streamTotalTimeout: Duration = .seconds(180)
    /// 回答问题的默认系统提示词。用户可在设置里用自定义 prompt 覆盖。
    public static let defaultLearningInstructions = """
    你是 Satori 的学习理解助手。默认使用简体中文，直接回答问题。
    优先依据用户提供的 PDF 原文；原文可能包含一页或多页，每段以【第 N 页】标注，
    请综合所有提供的页面回答，不要假装看到了未提供的页面。
    如果请求中包含独立的“用户在 PDF 中选中的原文”，那段文字就是用户此刻卡住的对象：先围绕它回答，
    再用当前页解释它为什么出现在这里。默认先给一句话结论，再给必要的原文依据和解释，
    避免把用户拖进一篇长教程；只有用户继续追问时才展开更多背景。
    如果用户说“看不懂”“好复杂”“字太多”“教材写得乱/没头没尾”，先承认阅读阻力，
    再把原文重排成“主线 → 因果/步骤 → 可以先放过的细节”；不要替教材辩护，也不要沿着原文顺序继续堆术语。
    如果用户问“这一章/整本书在讲什么”“主线是什么”“有什么值得看”或“怎么学”，切换到快速阅读地图：
    先给核心问题，再说明概念如何递进，最后标出优先读、可以先跳过和适合动手验证的部分；不要逐页复述，
    不要把目录改写成摘要。
    如果用户问“有没有错”“对不对”“靠谱吗”或质疑某个说法，先区分“原文明确写了什么、当前页能验证什么、
    可能只是 OCR/排版问题、当前材料无法判断什么”；不要只凭常识替教材改答案，也不要把缺少证据直接说成错误。
    如果用户明确询问“今日/实时/最新”的外部事实或要求找资料，优先依据网页来源回答现实问题；
    PDF 与问题无关时不要硬套“原文依据”，也不要把教材里的旧信息冒充当前事实。只有用户同时问
    “教材怎么说、现在有什么变化”时，才把 PDF 依据和网页结论分开说明。
    可以参考前面的本地学习问答理解“这里”“刚才”等追问，但本轮页面证据优先。
    历史对话中提到的图片当前不可见，若需图片细节请用户重新附图。
    回答依次包含“原文依据”“解释”；只有确实超出原文时才增加“补充推断”，并明确标注。
    原文依据要短，不要大段复述。解释应帮助用户建立概念联系，可以给一个具体例子。
    如果用户明确要求“简要”“一句话”“三句话”“先讲主线”或表示“字太多”，严格服从这个长度要求：
    只保留最关键的结论和必要依据，可以省略标题、例子和补充推断，不要为了套模板写成长答案。
    如果页面信息不足，直接说明缺少什么。不要要求用户做笔记或背诵。
    评价教材写法时只根据当前页面能观察到的结构（例如铺垫长、过渡弱、定义密集）；
    不要无依据地推断作者意图、概括“国内/国外教材”风格，或把个人感受说成事实。
    """

    /// 模型能力矩阵。未知模型按最保守的 [.text] 处理：宁可请求前给出
    /// 可读错误，也不要带图静默失败。
    public static func capabilities(for modelID: String) -> Set<ModelCapability> {
        switch modelID.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "qwen3.8-max", "qwen3.7-plus":
            [.text, .image, .webSearch]
        case "qwen3.7-flash":
            [.text, .image]
        default:
            [.text]
        }
    }

    /// 明确的外部资料请求自动启用本轮联网；普通的页内理解保持本地 PDF 优先，
    /// 不因为用户偶尔问一个现实世界的问题就把后续阅读都变成联网对话。
    public static func shouldAutoEnableWebSearch(for request: String) -> Bool {
        let normalized = request.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return false }
        let markers = [
            "找找", "找资料", "查资料", "查一下", "搜一下", "搜索", "给我找", "帮我找", "来源", "链接",
            "官方", "最新", "当前版本", "现在怎么样", "有没有过时", "过时了吗", "过时了么", "过时了没",
            "还适用", "现在还能用", "目前还能用",
            // Readers often test the boundary with a short live-fact query
            // after asking whether Satori can go online. Keep these phrases
            // specific enough that a textbook question such as “价格公式”
            // still stays PDF-local.
            "今日金价", "今天金价", "实时金价", "金价", "黄金价格",
            "今日汇率", "实时汇率", "当前汇率", "美元汇率",
            "今日价格", "当前价格", "实时价格", "现在价格",
            "天气预报", "实时天气", "今天星期几", "今天几号", "当前时间",
            "最新新闻", "最新消息", "实时新闻",
            "look up", "search", "latest", "official", "source", "sources", "current version"
        ]
        return markers.contains { normalized.contains($0) }
    }

    /// Keep a compact follow-up compact at the transport level too. Prompting
    /// alone is not enough: a model can still spend the whole budget repeating
    /// the evidence/explanation template after the reader says “简化”.
    public static func responseTokenBudget(for request: String, hasSelection: Bool = false) -> Int {
        let normalized = request.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return 1_400 }

        if normalized.contains("一句话") {
            return 260
        }
        if normalized.contains("三句话") || normalized.contains("两三句话") {
            return 360
        }
        if isQuickClarificationRequest(for: request) {
            return 520
        }
        if ["简要", "简化", "简短", "短一点", "字太多", "更简单", "简单点", "通俗点", "说人话", "先讲主线", "最重要的一个意思"].contains(where: normalized.contains) {
            return 560
        }
        if ["阅读路线图", "阅读地图", "概念怎样递进", "看本章路线"].contains(where: normalized.contains) {
            return 900
        }
        if normalized.contains("微实验") || normalized.contains("30 秒") {
            return 650
        }
        if hasSelection,
           !["完整代码", "逐行", "详细", "深入", "推导", "全部"].contains(where: normalized.contains) {
            return 700
        }
        return 1_400
    }

    /// A reader often interrupts a page with a fragment rather than a polished
    /// question: “这是什么？” / “什么意思？” / “这啥啊？”. These are not
    /// requests for a full explanation template; they are a small speed bump in
    /// the reading flow. Keep them compact even when a passage is selected, but
    /// leave an explicit request for depth in the normal path.
    public static func isQuickClarificationRequest(for request: String) -> Bool {
        let normalized = request
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
        guard !normalized.isEmpty,
              normalized.count <= 24,
              !["详细", "深入", "展开", "完整", "逐句", "逐行", "推导"].contains(where: normalized.contains)
        else { return false }

        let markers = [
            "什么意思", "啥意思", "这是什么", "这是什么东西", "这段是什么",
            "这啥", "这说的啥", "这段在说啥", "怎么理解"
        ]
        return markers.contains { normalized.contains($0) }
    }

    private let apiKey: String
    private let apiHost: URL
    private let modelID: String
    private let pageContent: LearningPageContent?
    /// 用户在 PDF 中主动选中的原文。它和问题分开传输，让模型明确
    /// 这段文字是本轮优先理解的对象，而不是普通聊天内容。
    private let selectionText: String?
    /// 用户正在回答上一轮主动发起的轻量理解验证；让模型按“判断 + 关键修正”
    /// 处理，而不是把这句话误当成一个新的普通问题。
    private let isVerificationResponse: Bool
    private let additionalImagesJPEG: [Data]
    private let conversationContext: [LearningConversationContext]
    private let allowsWebSearch: Bool
    private let instructions: String?
    private let transport: any AssistantTransport

    public init(
        apiKey: String,
        apiHost: URL = QwenLearningAssistant.defaultAPIHost,
        modelID: String = QwenLearningAssistant.defaultModelID,
        pageContent: LearningPageContent?,
        selectionText: String? = nil,
        isVerificationResponse: Bool = false,
        additionalImagesJPEG: [Data] = [],
        conversationContext: [LearningConversationContext] = [],
        allowsWebSearch: Bool = false,
        instructions: String? = nil,
        transport: (any AssistantTransport)? = nil
    ) {
        self.apiKey = apiKey
        self.apiHost = apiHost
        let normalizedModelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.modelID = normalizedModelID.isEmpty ? Self.defaultModelID : normalizedModelID
        self.pageContent = pageContent
        self.selectionText = selectionText?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.isVerificationResponse = isVerificationResponse
        self.additionalImagesJPEG = additionalImagesJPEG
        self.conversationContext = conversationContext
        self.allowsWebSearch = allowsWebSearch
        self.instructions = instructions
        self.transport = transport ?? URLSessionAssistantTransport()
    }

    public func explain(request: String, pageIndex: Int?) async -> LearningResponse {
        do {
            let budget = applyAttachmentBudget()
            let urlRequest = try makeURLRequest(question: request, pageIndex: pageIndex, streamsResponse: false, imageBudget: budget)
            let transportResponse = try await transport.send(urlRequest)
            guard (200..<300).contains(transportResponse.statusCode) else {
                let apiError = try? JSONDecoder().decode(APIErrorEnvelope.self, from: transportResponse.data)
                throw AssistantError.api(
                    statusCode: transportResponse.statusCode,
                    message: apiError?.error.message ?? "请求未成功"
                )
            }

            let envelope = try JSONDecoder().decode(ResponsesEnvelope.self, from: transportResponse.data)
            return try makeLearningResponse(from: envelope, pageIndex: pageIndex, imageBudget: budget)
        } catch {
            return LearningResponse(
                text: "暂时没能完成解释：\(error.localizedDescription)",
                sourceKind: .inference,
                pageIndex: pageIndex,
                errorMessage: error.localizedDescription
            )
        }
    }

    public func streamExplain(request: String, pageIndex: Int?) -> AsyncStream<LearningResponse> {
        AsyncStream { continuation in
            let worker = Task {
                do {
                    let budget = applyAttachmentBudget()
                    let urlRequest = try makeURLRequest(question: request, pageIndex: pageIndex, streamsResponse: true, imageBudget: budget)
                    let state = StreamState()

                    // 超时保护：总时长超过上限（连接挂起、服务端既不返回也不结束）时
                    // 抛 AssistantError.timeout，由外层转成可读错误，界面不再无限等待。
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        group.addTask {
                            try await Task.sleep(for: Self.streamTotalTimeout)
                            throw AssistantError.timeout
                        }
                        group.addTask {
                            for try await data in transport.stream(urlRequest) {
                                try Task.checkCancellation()
                                let event = try JSONDecoder().decode(ResponsesStreamEvent.self, from: data)
                                switch event.type {
                                case "response.output_text.delta":
                                    guard let delta = event.delta, !delta.isEmpty else { continue }
                                    state.text += delta
                                    continuation.yield(
                                        LearningResponse(
                                            text: state.text,
                                            sourceKind: predictedSourceKind,
                                            pageIndex: pageIndex,
                                            attachmentNotice: budget.notice
                                        )
                                    )
                                case "response.completed", "response.incomplete":
                                    guard let envelope = event.response else { throw AssistantError.invalidResponse }
                                    continuation.yield(try makeLearningResponse(from: envelope, pageIndex: pageIndex, imageBudget: budget))
                                    state.didComplete = true
                                case "response.failed":
                                    let message = event.response?.error?.message
                                        ?? event.error?.message
                                        ?? "Qwen 未能完成这次回答。"
                                    throw AssistantError.api(statusCode: nil, message: message)
                                default:
                                    continue
                                }
                            }
                        }
                        // 完成或超时，任一先结束就收尾。
                        try await group.next()
                        group.cancelAll()
                    }

                    try Task.checkCancellation()
                    if !state.didComplete {
                        let finalText = state.text.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !finalText.isEmpty else { throw AssistantError.emptyOutput }
                        // 没有收到完成事件就断流：按已收内容收尾并标记截断。
                        continuation.yield(
                            LearningResponse(
                                text: finalText,
                                sourceKind: predictedSourceKind,
                                pageIndex: pageIndex,
                                isTruncated: true,
                                attachmentNotice: budget.notice
                            )
                        )
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.yield(
                        LearningResponse(
                            text: "暂时没能完成解释：\(error.localizedDescription)",
                            sourceKind: .inference,
                            pageIndex: pageIndex,
                            errorMessage: error.localizedDescription
                        )
                    )
                    continuation.finish()
                }
            }
            continuation.onTermination = { @Sendable _ in worker.cancel() }
        }
    }

    /// 兼容入口：供尚未迁移到 `generateReviewQuestionsThrowing(pageIndex:count:)`
    /// 的调用点过渡使用。失败时返回空数组；新代码请用抛错版本以展示可读错误。
    public func generateReviewQuestions(pageIndex: Int?, count: Int = 3) async -> [ReviewQuestion] {
        do {
            return try await generateReviewQuestionsThrowing(pageIndex: pageIndex, count: count)
        } catch {
            return []
        }
    }

    /// 生成复习题。扫描页会作为图片与提示词一起发送；失败时抛出
    /// `AssistantError`（能力不足、HTTP 错误、解析失败等），不会吞成空数组。
    public func generateReviewQuestionsThrowing(pageIndex: Int?, count: Int = 3) async throws -> [ReviewQuestion] {
        let budget = applyAttachmentBudget()
        let urlRequest = try makeURLRequestForReview(pageIndex: pageIndex, count: count, imageBudget: budget)
        let transportResponse = try await transport.send(urlRequest)
        guard (200..<300).contains(transportResponse.statusCode) else {
            let apiError = try? JSONDecoder().decode(APIErrorEnvelope.self, from: transportResponse.data)
            throw AssistantError.api(
                statusCode: transportResponse.statusCode,
                message: apiError?.error.message ?? "请求未成功"
            )
        }
        let envelope = try JSONDecoder().decode(ResponsesEnvelope.self, from: transportResponse.data)
        let text = envelope.output.flatMap(\.content).compactMap(\.text).joined(separator: "\n")
        let result = ReviewQuestionParser.parseDetailed(text, pageIndex: pageIndex ?? 0)
        guard !result.questions.isEmpty else {
            if let message = envelope.error?.message {
                throw AssistantError.api(statusCode: nil, message: message)
            }
            if text.contains("看不清") || text.contains("无法看清") {
                throw AssistantError.reviewPageUnclear
            }
            throw AssistantError.reviewParsing(skippedLines: result.skippedLines)
        }
        return result.questions
    }

    // MARK: - 请求组装

    private func makeURLRequestForReview(pageIndex: Int?, count: Int, imageBudget: ImageBudgetResult) throws -> URLRequest {
        try validateCapabilities(imageBudget: imageBudget)
        let endpoint = apiHost.appending(path: "responses")
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let pageNumber = (pageIndex ?? 0) + 1
        let learnedContext = conversationContext.suffix(4)
            .map(Self.serializedTurn)
            .joined(separator: "\n\n")

        let reviewBody = """
        用户正在阅读 PDF 第 \(pageNumber) 页。

        用户在这本书里问过的内容：
        \(learnedContext.isEmpty ? "（还没有问过）" : learnedContext)

        我的要求：请根据上面提供的内容，生成 \(count) 道用于自测回忆的题目，帮助用户检验是否真的记住了这一页的核心概念。
        要求：
        - 题目要有意义，不是“这一页讲了什么”这种泛泛的问题；而是针对具体概念、原理、区别、代码含义出题。
        - 覆盖这一页真正重要的点，优先挑容易被看过就忘的。
        - 每题用一行输出，格式为：问题 | 参考答案
        - 题目和答案中不要使用 | 字符，因为 | 是题目与答案的分隔符。
        - 答案要短（一两句话），严格依据本页内容，不要编造本页没有的内容。
        - 如果看不清页面内容，直接说明“看不清页面内容”，不要编造题目或答案。
        - 只输出题目和答案，不要任何其他说明。
        """

        var content: [InputContent] = []
        content.append(contentsOf: makePageContentItems(pageNumber: pageNumber))
        content.append(contentsOf: makeAttachmentItems(imageBudget.images))
        content.append(.init(type: "input_text", text: reviewBody, imageURL: nil))

        let request = ResponsesRequest(
            model: modelID,
            instructions: "你是 Satori 的复习出题助手。根据给定的教材内容出回忆题。严格按格式“问题 | 答案”，一行一题，题目中不要使用 | 字符。只输出题目，不输出其它内容。",
            input: [InputMessage(role: "user", content: content)],
            tools: nil,
            store: false,
            stream: false,
            maxOutputTokens: 1400
        )
        urlRequest.httpBody = try JSONEncoder().encode(request)
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return urlRequest
    }

    private func makeURLRequest(question: String, pageIndex: Int?, streamsResponse: Bool, imageBudget: ImageBudgetResult) throws -> URLRequest {
        try validateCapabilities(imageBudget: imageBudget)
        let endpoint = apiHost.appending(path: "responses")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if streamsResponse {
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        }
        request.httpBody = try JSONEncoder().encode(
            makeRequest(question: question, pageIndex: pageIndex, streamsResponse: streamsResponse, imageBudget: imageBudget)
        )
        return request
    }

    private func makeRequest(question: String, pageIndex: Int?, streamsResponse: Bool, imageBudget: ImageBudgetResult) -> ResponsesRequest {
        let pageNumber = (pageIndex ?? 0) + 1

        var content: [InputContent] = []
        content.append(contentsOf: makePageContentItems(pageNumber: pageNumber))
        if let selectionText, !selectionText.isEmpty {
            content.append(.init(
                type: "input_text",
                text: "用户在 PDF 中选中的原文（这是本轮优先解释的对象）：\n「\(String(selectionText.prefix(4_000)))」\n\n选中内容默认先用一句话说明它在解决什么，再用不超过 3 点解释关键术语或步骤；除非用户明确要求完整代码、逐行解释、深入推导或全部细节，不要逐句翻译或大段复述。",
                imageURL: nil
            ))
        }
        if isVerificationResponse {
            content.append(.init(
                type: "input_text",
                text: "这是用户对上一轮“验证一下”情境的回答。请先判断用户是否抓住了核心，再给出原文依据和最关键的一处修正；不要重新出题，不要求死记硬背，也不要把整段答案重写成教程。",
                imageURL: nil
            ))
        }
        if Self.isQuickClarificationRequest(for: question) {
            content.append(.init(
                type: "input_text",
                text: "这是阅读中的一个短卡点。先直接用一句白话回答用户问的对象，不要先写“原文依据”“解释”等标题；最多三句短句，必要时给一个最小例子。当前页证据不足时直接说缺少什么。只有用户继续追问才展开，不要复述整页。",
                imageURL: nil
            ))
        }
        content.append(contentsOf: makeAttachmentItems(imageBudget.images))
        content.append(.init(type: "input_text", text: "我的问题：\(question)", imageURL: nil))

        var input = conversationContext.suffix(6).flatMap { turn in
            [
                InputMessage(role: "user", content: [
                    .init(type: "input_text", text: Self.serializedQuestion(turn), imageURL: nil)
                ]),
                InputMessage(role: "assistant", content: [
                    .init(type: "output_text", text: Self.serializedAnswer(turn), imageURL: nil)
                ])
            ]
        }
        input.append(.init(role: "user", content: content))

        return ResponsesRequest(
            model: modelID,
            instructions: instructions ?? Self.defaultLearningInstructions,
            input: input,
            tools: allowsWebSearch ? [.init(type: "web_search")] : nil,
            store: false,
            stream: streamsResponse,
            maxOutputTokens: Self.responseTokenBudget(for: question, hasSelection: selectionText?.isEmpty == false)
        )
    }

    /// 页上下文内容；没有页上下文（不带上下文提问）时返回 nil，请求里不夹带页面。
    private func makePageContentItems(pageNumber: Int) -> [InputContent] {
        switch pageContent {
        case .text(let text)?:
            return [.init(
                type: "input_text",
                text: "用户正在阅读教材 PDF 第 \(pageNumber) 页。\n\n以下是可参考的 PDF 原文（可能包含一页或多页，每段以【第 N 页】标注）：\n\(text)",
                imageURL: nil
            )]
        case .imageJPEG(let data)?:
            return [.init(
                type: "input_image",
                text: nil,
                imageURL: "data:image/jpeg;base64,\(data.base64EncodedString())"
            )]
        case let .textAndImage(text, data)?:
            return [
                .init(
                    type: "input_text",
                    text: "用户正在阅读教材 PDF 第 \(pageNumber) 页。\n\n以下是 PDF 的文字层，但其中可能有 OCR 识别错误：\n\(text)\n\n请同时核对下一项页面图像中的术语、数字、公式和符号，不要把明显的 OCR 错误当成原文。",
                    imageURL: nil
                ),
                .init(
                    type: "input_image",
                    text: nil,
                    imageURL: "data:image/jpeg;base64,\(data.base64EncodedString())"
                )
            ]
        case let .textAndImages(text, images)?:
            guard !images.isEmpty else {
                return [.init(
                    type: "input_text",
                    text: "用户正在阅读教材 PDF 第 \(pageNumber) 页。\n\n以下是可参考的 PDF 原文：\n\(text)",
                    imageURL: nil
                )]
            }
            let pageLabels = images.map { "第 \($0.pageIndex + 1) 页" }.joined(separator: "、")
            var items: [InputContent] = [
                .init(
                    type: "input_text",
                    text: "用户正在阅读教材 PDF（当前页第 \(pageNumber) 页）。\n\n以下是可参考的 PDF 原文（可能包含一页或多页，每段以【第 N 页】标注）：\n\(text)\n\n下面附上当前范围中含有图示或表格的页面图像（\(pageLabels)）。请把文字和对应页图像一起核对，尤其注意空间关系、箭头、数字、公式和表格列项。",
                    imageURL: nil
                )
            ]
            for image in images {
                items.append(.init(
                    type: "input_text",
                    text: "这是教材 PDF 第 \(image.pageIndex + 1) 页的页面图像。",
                    imageURL: nil
                ))
                items.append(.init(
                    type: "input_image",
                    text: nil,
                    imageURL: "data:image/jpeg;base64,\(image.jpegData.base64EncodedString())"
                ))
            }
            return items
        case nil:
            return []
        }
    }

    private func makeAttachmentItems(_ images: [Data]) -> [InputContent] {
        guard !images.isEmpty else { return [] }
        return [
            .init(type: "input_text", text: "用户为这次提问另外附加了 \(images.count) 张图片：", imageURL: nil)
        ] + images.map { data in
            .init(type: "input_image", text: nil, imageURL: "data:image/jpeg;base64,\(data.base64EncodedString())")
        }
    }

    private func validateCapabilities(imageBudget: ImageBudgetResult) throws {
        let capabilities = Self.capabilities(for: modelID)
        let needsImage: Bool = {
            if case .imageJPEG? = pageContent { return true }
            if case .textAndImage? = pageContent { return true }
            if case let .textAndImages(_, images)? = pageContent { return !images.isEmpty }
            return !imageBudget.images.isEmpty
        }()
        if needsImage && !capabilities.contains(.image) {
            throw AssistantError.capabilityUnavailable(capability: .image, modelID: modelID)
        }
        if allowsWebSearch && !capabilities.contains(.webSearch) {
            throw AssistantError.capabilityUnavailable(capability: .webSearch, modelID: modelID)
        }
    }

    // MARK: - 图片预算

    private enum ImageBudget {
        static let maximumCount = 4
        static let maximumTotalBytes = 3 * 1_024 * 1_024
    }

    private struct ImageBudgetResult: Sendable {
        let images: [Data]
        let notice: String?
    }

    /// 附图预算：最多 4 张、总字节 ≤ 3MB。超限先整体降质，仍超限则从
    /// 末尾丢弃，并通过 notice 提示用户。
    private func applyAttachmentBudget() -> ImageBudgetResult {
        var kept = Array(additionalImagesJPEG.prefix(ImageBudget.maximumCount))
        var dropped = additionalImagesJPEG.count - kept.count
        let originalTotal = kept.reduce(0) { $0 + $1.count }

        if originalTotal > ImageBudget.maximumTotalBytes {
            let recompressed = kept.compactMap { Self.recompressedJPEG($0, quality: 0.5) }
            let recompressedTotal = recompressed.reduce(0) { $0 + $1.count }
            if recompressed.count == kept.count, recompressedTotal < originalTotal {
                kept = recompressed
            }
            var total = kept.reduce(0) { $0 + $1.count }
            while total > ImageBudget.maximumTotalBytes, kept.count > 1 {
                total -= kept.removeLast().count
                dropped += 1
            }
        }

        let notice: String?
        if dropped > 0 {
            notice = "\(dropped) 张附图因体积超限被丢弃，已用其余图片继续。"
        } else if originalTotal > ImageBudget.maximumTotalBytes {
            notice = "附图较多，已压缩以控制请求体积。"
        } else {
            notice = nil
        }
        return ImageBudgetResult(images: kept, notice: notice)
    }

    private static func recompressedJPEG(_ data: Data, quality: Double) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            "public.jpeg" as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    // MARK: - 历史序列化

    /// 问（依据第 N 页，附图：…）：… 的前缀；无页码/附图时退回“问：”。
    private static func turnPrefix(_ turn: LearningConversationContext) -> String {
        var details: [String] = []
        if let pageIndex = turn.pageIndex {
            details.append("依据第 \(pageIndex + 1) 页")
        }
        if let summary = turn.attachmentSummary, !summary.isEmpty {
            details.append("附图：\(summary)")
        }
        return details.isEmpty ? "问" : "问（\(details.joined(separator: "，"))）"
    }

    /// 复习场景的单轮历史：问（依据第 N 页）：…\n答：…
    private static func serializedTurn(_ turn: LearningConversationContext) -> String {
        "\(turnPrefix(turn))：\(turn.question.prefix(1_200))\n答：\(turn.answer.prefix(6_000))"
    }

    /// 追问场景：历史以独立的 user/assistant 消息发送，文字与
    /// `serializedTurn` 保持一致（问（依据第 N 页）：… / 答：…）。
    private static func serializedQuestion(_ turn: LearningConversationContext) -> String {
        "\(turnPrefix(turn))：\(turn.question.prefix(1_200))"
    }

    private static func serializedAnswer(_ turn: LearningConversationContext) -> String {
        "答：\(turn.answer.prefix(6_000))"
    }

    // MARK: - 响应解析

    private func makeLearningResponse(
        from envelope: ResponsesEnvelope,
        pageIndex: Int?,
        imageBudget: ImageBudgetResult
    ) throws -> LearningResponse {
        let contents = envelope.output.flatMap(\.content)
        let text = contents.compactMap(\.text).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            if let message = envelope.error?.message {
                throw AssistantError.api(statusCode: nil, message: message)
            }
            throw AssistantError.emptyOutput
        }

        let citations = contents
            .flatMap(\.annotations)
            .compactMap { annotation -> LearningCitation? in
                guard annotation.type == "url_citation",
                      let urlString = annotation.url,
                      let url = URL(string: urlString) else { return nil }
                return LearningCitation(title: annotation.title ?? url.host() ?? urlString, url: url)
            }
            + envelope.output
                .compactMap(\.action)
                .flatMap(\.sources)
                .compactMap { source -> LearningCitation? in
                    guard let url = URL(string: source.url) else { return nil }
                    return LearningCitation(title: url.host() ?? source.url, url: url)
                }

        let isTruncated = envelope.status == "incomplete" || envelope.incompleteDetails != nil
        let sourceKind: LearningSourceKind
        if envelope.error?.message != nil {
            sourceKind = .inference
        } else if !citations.isEmpty {
            sourceKind = .web
        } else if !imageBudget.images.isEmpty {
            sourceKind = .relatedMaterial
        } else if pageIndex != nil {
            sourceKind = .currentPDF
        } else {
            sourceKind = .inference
        }

        return LearningResponse(
            text: text,
            sourceKind: sourceKind,
            pageIndex: pageIndex,
            citations: uniqueCitations(citations),
            isTruncated: isTruncated,
            errorMessage: envelope.error?.message,
            attachmentNotice: imageBudget.notice
        )
    }

    /// 流式期间的预判标签：按开关（联网搜索 → 附图 → 当前页）。
    private var predictedSourceKind: LearningSourceKind {
        if allowsWebSearch { return .web }
        if !additionalImagesJPEG.isEmpty { return .relatedMaterial }
        return .currentPDF
    }

    private func uniqueCitations(_ citations: [LearningCitation]) -> [LearningCitation] {
        var seen = Set<URL>()
        return citations.filter { seen.insert($0.url).inserted }
    }
}

private struct URLSessionAssistantTransport: AssistantTransport {
    func send(_ request: URLRequest) async throws -> AssistantTransportResponse {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AssistantError.invalidResponse
        }
        return AssistantTransportResponse(data: data, statusCode: httpResponse.statusCode)
    }

    func stream(_ request: URLRequest) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let worker = Task {
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    guard let httpResponse = response as? HTTPURLResponse else {
                        throw AssistantError.invalidResponse
                    }
                    guard (200..<300).contains(httpResponse.statusCode) else {
                        var errorData = Data()
                        for try await byte in bytes { errorData.append(byte) }
                        let apiError = try? JSONDecoder().decode(APIErrorEnvelope.self, from: errorData)
                        throw AssistantError.api(
                            statusCode: httpResponse.statusCode,
                            message: apiError?.error.message ?? "请求未成功"
                        )
                    }

                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard line.hasPrefix("data:") else { continue }
                        let payload = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                        guard !payload.isEmpty, payload != "[DONE]" else { continue }
                        continuation.yield(Data(payload.utf8))
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in worker.cancel() }
        }
    }
}

/// 流式处理期间的收尾状态：只在流式任务里写、主流程读，单写者，
/// 用 @unchecked Sendable 避免跨并发闭包捕获可变变量。
private final class StreamState: @unchecked Sendable {
    var text = ""
    var didComplete = false
}

private struct ResponsesRequest: Encodable {
    let model: String
    let instructions: String
    let input: [InputMessage]
    let tools: [Tool]?
    let store: Bool
    let stream: Bool
    let maxOutputTokens: Int

    enum CodingKeys: String, CodingKey {
        case model, instructions, input, tools, store, stream
        case maxOutputTokens = "max_output_tokens"
    }
}

private struct InputMessage: Encodable {
    let role: String
    let content: [InputContent]
}

private struct InputContent: Encodable {
    let type: String
    let text: String?
    let imageURL: String?

    enum CodingKeys: String, CodingKey {
        case type, text
        case imageURL = "image_url"
    }
}

private struct Tool: Encodable { let type: String }

private struct ResponsesEnvelope: Decodable {
    let output: [OutputItem]
    let status: String?
    let incompleteDetails: IncompleteDetails?
    let error: APIErrorEnvelope.APIError?

    enum CodingKeys: String, CodingKey {
        case output, status, error
        case incompleteDetails = "incomplete_details"
    }
}

private struct IncompleteDetails: Decodable {
    let reason: String?
}

private struct ResponsesStreamEvent: Decodable {
    let type: String
    let delta: String?
    let response: ResponsesEnvelope?
    let error: APIErrorEnvelope.APIError?

    enum CodingKeys: String, CodingKey { case type, delta, response, error }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        delta = try container.decodeIfPresent(String.self, forKey: .delta)
        response = try container.decodeIfPresent(ResponsesEnvelope.self, forKey: .response)
        error = try container.decodeIfPresent(APIErrorEnvelope.APIError.self, forKey: .error)
    }
}

private struct OutputItem: Decodable {
    let content: [OutputContent]
    let action: WebSearchAction?

    enum CodingKeys: String, CodingKey { case content, action }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        content = try container.decodeIfPresent([OutputContent].self, forKey: .content) ?? []
        action = try container.decodeIfPresent(WebSearchAction.self, forKey: .action)
    }
}

private struct WebSearchAction: Decodable {
    let sources: [WebSearchSource]

    enum CodingKeys: String, CodingKey { case sources }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sources = try container.decodeIfPresent([WebSearchSource].self, forKey: .sources) ?? []
    }
}

private struct WebSearchSource: Decodable {
    let url: String
}

private struct OutputContent: Decodable {
    let text: String?
    let annotations: [OutputAnnotation]

    enum CodingKeys: String, CodingKey { case text, annotations }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decodeIfPresent(String.self, forKey: .text)
        annotations = try container.decodeIfPresent([OutputAnnotation].self, forKey: .annotations) ?? []
    }
}

private struct OutputAnnotation: Decodable {
    let type: String
    let title: String?
    let url: String?
}

private struct APIErrorEnvelope: Decodable {
    struct APIError: Decodable { let message: String }
    let error: APIError
}
