import Foundation
import SatoriCore

@main
struct SatoriCoreTests {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "satori-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let store = LearningPlanStore(fileURL: root.appending(path: "learning-plan.json"))
        var plan = LearningPlan()
        precondition(plan.courses.count == 3, "Expected three initial course workspaces")

        let courseID = plan.courses[0].id
        let documentID = UUID()
        plan.courses[0].documents.append(
            StudyDocument(id: documentID, displayName: "fixture", localPath: "/tmp/fixture.pdf", pageCount: 12, contentKind: .scanned, readingPosition: .init(pageIndex: 7, normalizedPageOffset: 0.4))
        )
        try await store.save(plan)
        let restored = try await store.load()
        let document = try! XCTUnwrap(restored.courses.first(where: { $0.id == courseID })?.documents.first(where: { $0.id == documentID }))
        precondition(document.readingPosition.pageIndex == 7, "Expected reading page to persist")
        precondition(document.readingPosition.normalizedPageOffset == 0.4, "Expected reading offset to persist")

        let response = await UnconfiguredLearningAssistant().explain(request: "解释", pageIndex: 7)
        precondition(response.sourceKind == .inference, "Expected explicit source label")

        let apiResponse = await QwenLearningAssistant(
            apiKey: "fixture-key",
            pageContent: .text("fixture page text"),
            allowsWebSearch: true,
            transport: FixtureAssistantTransport(
                expectedEndpoint: "https://dashscope.aliyuncs.com/compatible-mode/v1/responses",
                expectedModelID: "qwen3.8-max",
                expectedImageCount: 0,
                expectsWebSearch: true
            )
        ).explain(request: "解释这一页", pageIndex: 2)
        precondition(apiResponse.text == "fixture explanation", "Expected Responses API output text")
        precondition(apiResponse.sourceKind == .web, "Expected web source label when citations are returned")
        precondition(apiResponse.citations.first?.url.absoluteString == "https://example.com/source", "Expected URL citation")

        let imageResponse = await QwenLearningAssistant(
            apiKey: "fixture-key",
            apiHost: URL(string: "https://workspace.cn-beijing.maas.aliyuncs.com/compatible-mode/v1/")!,
            modelID: "qwen3.7-plus",
            pageContent: .imageJPEG(Data([0xFF, 0xD8, 0xFF])),
            transport: FixtureAssistantTransport(
                expectedEndpoint: "https://workspace.cn-beijing.maas.aliyuncs.com/compatible-mode/v1/responses",
                expectedModelID: "qwen3.7-plus",
                expectedImageCount: 1,
                expectsWebSearch: false
            )
        ).explain(request: "解释扫描页", pageIndex: 4)
        precondition(imageResponse.text == "fixture explanation", "Expected scanned-page output text")

        let streamingAssistant = QwenLearningAssistant(
            apiKey: "fixture-key",
            pageContent: .text("fixture page text"),
            additionalImagesJPEG: [Data([0xFF, 0xD8, 0xFF])],
            allowsWebSearch: true,
            transport: FixtureAssistantTransport(
                expectedEndpoint: "https://dashscope.aliyuncs.com/compatible-mode/v1/responses",
                expectedModelID: "qwen3.8-max",
                expectedImageCount: 1,
                expectsWebSearch: true
            )
        )
        var streamUpdates: [LearningResponse] = []
        for await update in streamingAssistant.streamExplain(request: "结合附图解释", pageIndex: 5) {
            streamUpdates.append(update)
        }
        precondition(streamUpdates.first?.text == "fixture ", "Expected first streaming text delta")
        precondition(streamUpdates.last?.text == "fixture explanation", "Expected assembled streaming response")
        precondition(streamUpdates.last?.citations.first?.url.absoluteString == "https://example.com/source", "Expected final streaming citations")
        print("Satori core checks passed")
    }
}

private func XCTUnwrap<T>(_ value: T?) throws -> T {
    guard let value else { throw TestError.missingValue }
    return value
}

private enum TestError: Error { case missingValue }

private struct FixtureAssistantTransport: AssistantTransport {
    let expectedEndpoint: String
    let expectedModelID: String
    let expectedImageCount: Int
    let expectsWebSearch: Bool

    func send(_ request: URLRequest) async throws -> AssistantTransportResponse {
        try validate(request, expectsStreaming: false)

        return AssistantTransportResponse(data: Data(Self.completedResponse.utf8), statusCode: 200)
    }

    func stream(_ request: URLRequest) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            do {
                try validate(request, expectsStreaming: true)
                [
                    #"{"type":"response.output_text.delta","delta":"fixture "}"#,
                    #"{"type":"response.output_text.delta","delta":"explanation"}"#,
                    #"{"type":"response.completed","response":\#(Self.completedResponse)}"#
                ].forEach { continuation.yield(Data($0.utf8)) }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }

    private func validate(_ request: URLRequest, expectsStreaming: Bool) throws {
        precondition(request.url?.absoluteString == expectedEndpoint, "Expected Responses endpoint")
        precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-key", "Expected bearer authentication")
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        precondition(json["model"] as? String == expectedModelID, "Expected configured Qwen learning model")
        precondition(json["store"] as? Bool == false, "Expected response storage to be disabled")
        precondition(json["stream"] as? Bool == expectsStreaming, "Expected configured streaming mode")
        let tools = json["tools"] as? [[String: String]]
        precondition((tools?.first?["type"] == "web_search") == expectsWebSearch, "Expected opt-in web search behavior")

        let input = try XCTUnwrap(json["input"] as? [[String: Any]])
        let content = try XCTUnwrap(input.first?["content"] as? [[String: Any]])
        let images = content.filter { $0["type"] as? String == "input_image" }
        precondition(images.count == expectedImageCount, "Expected page and attachment image inputs")
        precondition(images.allSatisfy { ($0["image_url"] as? String)?.hasPrefix("data:image/jpeg;base64,") == true }, "Expected Base64 JPEG data URLs")
        if expectedImageCount == 0 {
            precondition(content.first?["type"] as? String == "input_text", "Expected extracted PDF text input")
        }
    }

    private static let completedResponse = """
        {
          "output": [{
            "type": "web_search_call",
            "status": "completed",
            "action": {
              "type": "search",
              "query": "fixture query",
              "sources": [{
                "type": "url",
                "url": "https://example.com/source"
              }]
            }
          }, {
            "type": "message",
            "content": [{
              "type": "output_text",
              "text": "fixture explanation",
              "annotations": []
            }]
          }]
        }
        """
}
