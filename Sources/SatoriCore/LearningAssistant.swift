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

public struct LearningCitation: Sendable, Equatable, Identifiable {
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
}

public protocol LearningAssistant: Sendable {
    func explain(request: String, pageIndex: Int?) async -> LearningResponse
}

public struct UnconfiguredLearningAssistant: LearningAssistant {
    public init() {}

    public func explain(request: String, pageIndex: Int?) async -> LearningResponse {
        LearningResponse(
            text: "AI 理解助手尚未配置百炼 API Key 和 API Host。Satori 已保留你的阅读位置；配置后，这里会优先结合当前 PDF 的页码解释问题。",
            sourceKind: .inference,
            pageIndex: pageIndex
        )
    }
}

public struct QwenLearningAssistant: LearningAssistant {
    public static let defaultModelID = "qwen3.8-max"

    private let apiKey: String
    private let apiHost: URL
    private let modelID: String
    private let pageContent: LearningPageContent
    private let allowsWebSearch: Bool
    private let transport: any AssistantTransport

    public init(
        apiKey: String,
        apiHost: URL,
        modelID: String = QwenLearningAssistant.defaultModelID,
        pageContent: LearningPageContent,
        allowsWebSearch: Bool = false,
        transport: (any AssistantTransport)? = nil
    ) {
        self.apiKey = apiKey
        self.apiHost = apiHost
        let normalizedModelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.modelID = normalizedModelID.isEmpty ? Self.defaultModelID : normalizedModelID
        self.pageContent = pageContent
        self.allowsWebSearch = allowsWebSearch
        self.transport = transport ?? URLSessionAssistantTransport()
    }

    public func explain(request: String, pageIndex: Int?) async -> LearningResponse {
        do {
            let endpoint = apiHost.appending(path: "responses")
            var urlRequest = URLRequest(url: endpoint)
            urlRequest.httpMethod = "POST"
            urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            urlRequest.httpBody = try JSONEncoder().encode(makeRequest(question: request, pageIndex: pageIndex))

            let transportResponse = try await transport.send(urlRequest)
            guard (200..<300).contains(transportResponse.statusCode) else {
                let apiError = try? JSONDecoder().decode(APIErrorEnvelope.self, from: transportResponse.data)
                throw AssistantError.api(apiError?.error.message ?? "百炼返回了错误 \(transportResponse.statusCode)")
            }

            let envelope = try JSONDecoder().decode(ResponsesEnvelope.self, from: transportResponse.data)
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
        } catch {
            return LearningResponse(
                text: "暂时没能完成解释：\(error.localizedDescription)",
                sourceKind: .inference,
                pageIndex: pageIndex
            )
        }
    }

    private func makeRequest(question: String, pageIndex: Int?) -> ResponsesRequest {
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

        return ResponsesRequest(
            model: modelID,
            instructions: """
            你是 Satori 的学习理解助手。默认使用简体中文，直接回答问题。
            优先依据用户提供的当前 PDF 页面；不要假装看到了未提供的页面。
            回答依次包含“原文依据”“解释”；只有确实超出原文时才增加“补充推断”，并明确标注。
            原文依据要短，不要大段复述。解释应帮助用户建立概念联系，可以给一个具体例子。
            如果页面信息不足，直接说明缺少什么。不要要求用户做笔记或背诵。
            """,
            input: [
                .init(role: "user", content: [
                    context,
                    .init(type: "input_text", text: "我的问题：\(question)", imageURL: nil)
                ])
            ],
            tools: allowsWebSearch ? [.init(type: "web_search")] : nil,
            store: false,
            maxOutputTokens: 1400
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
}

private struct ResponsesRequest: Encodable {
    let model: String
    let instructions: String
    let input: [InputMessage]
    let tools: [Tool]?
    let store: Bool
    let maxOutputTokens: Int

    enum CodingKeys: String, CodingKey {
        case model, instructions, input, tools, store
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

private enum AssistantError: LocalizedError {
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
