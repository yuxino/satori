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
    public var citations: [LearningCitation]

    public init(text: String, sourceKind: LearningSourceKind, pageIndex: Int? = nil, citations: [LearningCitation] = []) {
        self.text = text
        self.sourceKind = sourceKind
        self.pageIndex = pageIndex
        self.citations = citations
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

public enum LearningPageContent: Sendable, Equatable {
    case text(String)
    case imageJPEG(Data)
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

public struct QwenLearningAssistant: LearningAssistant {
    public static let defaultModelID = "qwen3.8-max"
    public static let defaultAPIHost = URL(string: "https://dashscope.aliyuncs.com/compatible-mode/v1")!

    private let apiKey: String
    private let apiHost: URL
    private let modelID: String
    private let pageContent: LearningPageContent
    private let additionalImagesJPEG: [Data]
    private let conversationContext: [LearningConversationContext]
    private let allowsWebSearch: Bool
    private let transport: any AssistantTransport

    public init(
        apiKey: String,
        apiHost: URL = QwenLearningAssistant.defaultAPIHost,
        modelID: String = QwenLearningAssistant.defaultModelID,
        pageContent: LearningPageContent,
        additionalImagesJPEG: [Data] = [],
        conversationContext: [LearningConversationContext] = [],
        allowsWebSearch: Bool = false,
        transport: (any AssistantTransport)? = nil
    ) {
        self.apiKey = apiKey
        self.apiHost = apiHost
        let normalizedModelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.modelID = normalizedModelID.isEmpty ? Self.defaultModelID : normalizedModelID
        self.pageContent = pageContent
        self.additionalImagesJPEG = additionalImagesJPEG
        self.conversationContext = conversationContext
        self.allowsWebSearch = allowsWebSearch
        self.transport = transport ?? URLSessionAssistantTransport()
    }

    public func explain(request: String, pageIndex: Int?) async -> LearningResponse {
        do {
            let urlRequest = try makeURLRequest(question: request, pageIndex: pageIndex, streamsResponse: false)
            let transportResponse = try await transport.send(urlRequest)
            guard (200..<300).contains(transportResponse.statusCode) else {
                let apiError = try? JSONDecoder().decode(APIErrorEnvelope.self, from: transportResponse.data)
                throw AssistantError.api(apiError?.error.message ?? "百炼返回了错误 \(transportResponse.statusCode)")
            }

            let envelope = try JSONDecoder().decode(ResponsesEnvelope.self, from: transportResponse.data)
            return try makeLearningResponse(from: envelope, pageIndex: pageIndex)
        } catch {
            return LearningResponse(
                text: "暂时没能完成解释：\(error.localizedDescription)",
                sourceKind: .inference,
                pageIndex: pageIndex
            )
        }
    }

    public func streamExplain(request: String, pageIndex: Int?) -> AsyncStream<LearningResponse> {
        AsyncStream { continuation in
            let worker = Task {
                do {
                    let urlRequest = try makeURLRequest(question: request, pageIndex: pageIndex, streamsResponse: true)
                    var streamedText = ""
                    var didComplete = false

                    for try await data in transport.stream(urlRequest) {
                        try Task.checkCancellation()
                        let event = try JSONDecoder().decode(ResponsesStreamEvent.self, from: data)
                        switch event.type {
                        case "response.output_text.delta":
                            guard let delta = event.delta, !delta.isEmpty else { continue }
                            streamedText += delta
                            continuation.yield(
                                LearningResponse(text: streamedText, sourceKind: .currentPDF, pageIndex: pageIndex)
                            )
                        case "response.completed":
                            guard let envelope = event.response else { throw AssistantError.invalidResponse }
                            continuation.yield(try makeLearningResponse(from: envelope, pageIndex: pageIndex))
                            didComplete = true
                        case "response.failed":
                            throw AssistantError.api(event.error?.message ?? "Qwen 未能完成这次回答。")
                        default:
                            continue
                        }
                    }

                    try Task.checkCancellation()
                    if !didComplete {
                        let finalText = streamedText.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !finalText.isEmpty else { throw AssistantError.emptyOutput }
                        continuation.yield(
                            LearningResponse(text: finalText, sourceKind: .currentPDF, pageIndex: pageIndex)
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
                            pageIndex: pageIndex
                        )
                    )
                    continuation.finish()
                }
            }
            continuation.onTermination = { @Sendable _ in worker.cancel() }
        }
    }

    /// Generates retrieval-practice questions grounded in what the reader
    /// actually saw and asked. The model returns lines of `问题 | 答案`, which
    /// we parse into review questions — deliberately no code, no commentary,
    /// so the answer can be checked against what the page says.
    public func generateReviewQuestions(
        pageIndex: Int?,
        count: Int = 3
    ) async -> [ReviewQuestion] {
        do {
            let urlRequest = try makeURLRequestForReview(pageIndex: pageIndex, count: count)
            let transportResponse = try await transport.send(urlRequest)
            guard (200..<300).contains(transportResponse.statusCode) else {
                let apiError = try? JSONDecoder().decode(APIErrorEnvelope.self, from: transportResponse.data)
                throw AssistantError.api(apiError?.error.message ?? "百炼返回了错误 \(transportResponse.statusCode)")
            }
            let envelope = try JSONDecoder().decode(ResponsesEnvelope.self, from: transportResponse.data)
            let text = envelope.output.flatMap(\.content).compactMap(\.text).joined(separator: "\n")
            return ReviewQuestionParser.parse(text, pageIndex: pageIndex ?? 0)
        } catch {
            return []
        }
    }

    private func makeURLRequestForReview(pageIndex: Int?, count: Int) throws -> URLRequest {
        let endpoint = apiHost.appending(path: "responses")
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let pageNumber = (pageIndex ?? 0) + 1
        let pageText: String
        switch pageContent {
        case let .text(text): pageText = text
        case .imageJPEG: pageText = "（这一页是扫描图，无法提供原文文字）"
        }
        let learnedContext = conversationContext.suffix(4).map { "问：\($0.question)\n答：\($0.answer.prefix(1_200))" }.joined(separator: "\n\n")

        let reviewBody = """
        用户正在阅读 PDF 第 \(pageNumber) 页。

        本页原文：
        \(pageText)

        用户在这本书里问过的内容：
        \(learnedContext.isEmpty ? "（还没有问过）" : learnedContext)

        我的要求：请根据上面的内容，生成 \(count) 道用于自测回忆的题目，帮助用户检验是否真的记住了这一页的核心概念。
        要求：
        - 题目要有意义，不是“这一页讲了什么”这种泛泛的问题；而是针对具体概念、原理、区别、代码含义出题。
        - 覆盖这一页真正重要的点，优先挑容易被看过就忘的。
        - 每题用一行输出，格式为：问题 | 参考答案
        - 答案要短（一两句话），严格依据本页原文，不要编造本页没有的内容。
        - 只输出题目和答案，不要任何其他说明。
        """

        let body: [String: Any] = [
            "model": modelID,
            "instructions": "你是 Satori 的复习出题助手。根据给定的教材原文出回忆题。严格按格式“问题 | 答案”，一行一题。只输出题目，不输出其它内容。",
            "input": [
                ["role": "user", "content": [["type": "input_text", "text": reviewBody]]]
            ],
            "store": false,
            "stream": false,
            "max_output_tokens": 1400
        ]
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return urlRequest
    }

    private func makeURLRequest(question: String, pageIndex: Int?, streamsResponse: Bool) throws -> URLRequest {
        let endpoint = apiHost.appending(path: "responses")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if streamsResponse {
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        }
        request.httpBody = try JSONEncoder().encode(
            makeRequest(question: question, pageIndex: pageIndex, streamsResponse: streamsResponse)
        )
        return request
    }

    private func makeRequest(question: String, pageIndex: Int?, streamsResponse: Bool) -> ResponsesRequest {
        let pageNumber = (pageIndex ?? 0) + 1
        let context: InputContent
        switch pageContent {
        case let .text(text):
            context = .init(type: "input_text", text: "用户正在阅读 PDF 第 \(pageNumber) 页。\n\n当前页原文：\n\(text)", imageURL: nil)
        case let .imageJPEG(data):
            context = .init(
                type: "input_image",
                text: nil,
                imageURL: "data:image/jpeg;base64,\(data.base64EncodedString())"
            )
        }

        var content = [context]
        if !additionalImagesJPEG.isEmpty {
            content.append(
                .init(type: "input_text", text: "用户为这个问题另外附加了 \(additionalImagesJPEG.count) 张图片：", imageURL: nil)
            )
            content.append(contentsOf: additionalImagesJPEG.map { data in
                .init(type: "input_image", text: nil, imageURL: "data:image/jpeg;base64,\(data.base64EncodedString())")
            })
        }
        content.append(.init(type: "input_text", text: "我的问题：\(question)", imageURL: nil))

        var input = conversationContext.suffix(6).flatMap { turn in
            [
                InputMessage(role: "user", content: [
                    .init(type: "input_text", text: String(turn.question.prefix(1_200)), imageURL: nil)
                ]),
                InputMessage(role: "assistant", content: [
                    .init(type: "output_text", text: String(turn.answer.prefix(6_000)), imageURL: nil)
                ])
            ]
        }
        input.append(.init(role: "user", content: content))

        return ResponsesRequest(
            model: modelID,
            instructions: """
            你是 Satori 的学习理解助手。默认使用简体中文，直接回答问题。
            优先依据用户提供的当前 PDF 页面；不要假装看到了未提供的页面。
            可以参考前面的本地学习问答理解“这里”“刚才”等追问，但本轮页面证据优先。
            回答依次包含“原文依据”“解释”；只有确实超出原文时才增加“补充推断”，并明确标注。
            原文依据要短，不要大段复述。解释应帮助用户建立概念联系，可以给一个具体例子。
            如果页面信息不足，直接说明缺少什么。不要要求用户做笔记或背诵。
            """,
            input: input,
            tools: allowsWebSearch ? [.init(type: "web_search")] : nil,
            store: false,
            stream: streamsResponse,
            maxOutputTokens: 1400
        )
    }

    private func makeLearningResponse(from envelope: ResponsesEnvelope, pageIndex: Int?) throws -> LearningResponse {
        let contents = envelope.output.flatMap(\.content)
        let text = contents.compactMap(\.text).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw AssistantError.emptyOutput }

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

        return LearningResponse(
            text: text,
            sourceKind: citations.isEmpty ? .currentPDF : .web,
            pageIndex: pageIndex,
            citations: uniqueCitations(citations)
        )
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
                        throw AssistantError.api(apiError?.error.message ?? "百炼返回了错误 \(httpResponse.statusCode)")
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

private enum AssistantError: LocalizedError, Sendable {
    case invalidResponse
    case emptyOutput
    case api(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "百炼返回了无法识别的响应。"
        case .emptyOutput: "Qwen 没有返回可显示的文字。"
        case let .api(message): message
        }
    }
}
