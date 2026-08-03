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

        let apiResponse = await OpenAILearningAssistant(
            apiKey: "fixture-key",
            pageContent: .text("fixture page text"),
            allowsWebSearch: true,
            transport: FixtureOpenAITransport()
        ).explain(request: "解释这一页", pageIndex: 2)
        precondition(apiResponse.text == "fixture explanation", "Expected Responses API output text")
        precondition(apiResponse.sourceKind == .web, "Expected web source label when citations are returned")
        precondition(apiResponse.citations.first?.url.absoluteString == "https://example.com/source", "Expected URL citation")
        print("Satori core checks passed")
    }
}

private func XCTUnwrap<T>(_ value: T?) throws -> T {
    guard let value else { throw TestError.missingValue }
    return value
}

private enum TestError: Error { case missingValue }

private struct FixtureOpenAITransport: OpenAITransport {
    func send(_ request: URLRequest) async throws -> OpenAITransportResponse {
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        precondition(json["model"] as? String == "gpt-5.6-terra", "Expected balanced learning model")
        precondition(json["store"] as? Bool == false, "Expected response storage to be disabled")
        let tools = json["tools"] as? [[String: String]]
        precondition(tools?.first?["type"] == "web_search", "Expected opt-in web search tool")

        let fixture = """
        {
          "output": [{
            "type": "message",
            "content": [{
              "type": "output_text",
              "text": "fixture explanation",
              "annotations": [{
                "type": "url_citation",
                "title": "Fixture source",
                "url": "https://example.com/source"
              }]
            }]
          }]
        }
        """
        return OpenAITransportResponse(data: Data(fixture.utf8), statusCode: 200)
    }
}
