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

        let firstDocumentID = UUID()
        let secondDocumentID = UUID()
        let sessionFile = root.appending(path: "learning-sessions.json")
        let sessionStore = LearningSessionStore(fileURL: sessionFile)
        let savedTurn = LearningTurn(
            question: "为什么需要循环？",
            answer: "循环把重复规则写成有限步骤。",
            pageIndex: 2,
            sourceKind: .currentPDF,
            attachmentCount: 1,
            selectionText: "把重复规则写成有限步骤"
        )
        try await sessionStore.save([savedTurn], for: firstDocumentID)
        try await sessionStore.save([
            LearningTurn(question: "什么是进程？", answer: "运行中的程序。", pageIndex: 8, sourceKind: .currentPDF)
        ], for: secondDocumentID)
        let restoredSessionStore = LearningSessionStore(fileURL: sessionFile)
        let restoredFirstTurns = try await restoredSessionStore.turns(for: firstDocumentID)
        let restoredSecondTurns = try await restoredSessionStore.turns(for: secondDocumentID)
        precondition(restoredFirstTurns == [savedTurn], "Expected first document learning session to persist")
        precondition(restoredSecondTurns.count == 1, "Expected document sessions to remain isolated")
        try await restoredSessionStore.save([], for: firstDocumentID)
        let replacedFirstTurns = try await restoredSessionStore.turns(for: firstDocumentID)
        precondition(replacedFirstTurns.isEmpty, "Expected a document session to be replaceable")
        try await restoredSessionStore.clear(for: secondDocumentID)
        let clearedSecondTurns = try await restoredSessionStore.turns(for: secondDocumentID)
        precondition(clearedSecondTurns.isEmpty, "Expected clearing one document session")

        // Regression: switching books used to wipe records. A single store must
        // keep every book's turns intact when writes for different documents
        // interleave, even reusing the file after a fresh load.
        let interleaveFile = root.appending(path: "interleave-sessions.json")
        let bookA = UUID()
        let bookB = UUID()
        let interleaveStore = LearningSessionStore(fileURL: interleaveFile)
        try await interleaveStore.save([
            LearningTurn(question: "A1", answer: "答案 A1", pageIndex: 0, sourceKind: .currentPDF)
        ], for: bookA)
        try await interleaveStore.save([
            LearningTurn(question: "B1", answer: "答案 B1", pageIndex: 0, sourceKind: .currentPDF)
        ], for: bookB)
        // A late write for book A (as if its stream finished after the switch).
        try await interleaveStore.save([
            LearningTurn(question: "A1", answer: "答案 A1", pageIndex: 0, sourceKind: .currentPDF),
            LearningTurn(question: "A2", answer: "答案 A2", pageIndex: 1, sourceKind: .currentPDF)
        ], for: bookA)
        let survivingA = try await interleaveStore.turns(for: bookA)
        let survivingB = try await interleaveStore.turns(for: bookB)
        precondition(survivingA.count == 2, "Expected book A turns to persist after a late write")
        precondition(survivingB.count == 1, "Expected book B turns to survive a sibling's write")

        let markdown = """
        **原文依据**

        这是包含 `t=t*i` 的解释。

        - 第一条
        - 第二条

        1. 第一步
        2. 第二步

        > 重要联系

        ```c
        for (i = 2; i <= 10; i++) {
            t *= i;
        }
        ```
        """
        let markdownBlocks = LearningMarkdownParser.parse(markdown)
        precondition(markdownBlocks.first == .heading(level: 3, text: "原文依据"), "Expected bold section label to become a heading")
        precondition(markdownBlocks.contains(.unorderedList(["第一条", "第二条"])), "Expected unordered list parsing")
        precondition(
            markdownBlocks.contains(.orderedList([
                LearningOrderedItem(number: 1, text: "第一步"),
                LearningOrderedItem(number: 2, text: "第二步")
            ])),
            "Expected ordered list parsing"
        )
        precondition(markdownBlocks.contains(.quote("重要联系")), "Expected quote parsing")
        precondition(markdownBlocks.contains(.code(language: "c", content: "for (i = 2; i <= 10; i++) {\n    t *= i;\n}")), "Expected fenced code parsing")

        // Regression: an ordered list broken up by explanatory paragraphs used
        // to render every item as "1" because each fragment was its own list
        // renumbered from the array index. Numbers must follow the source text.
        let interruptedList = """
        1. 第一点
        例如：具体说明一。
        2. 第二点
        例如：具体说明二。
        3. 第三点
        """
        let interruptedBlocks = LearningMarkdownParser.parse(interruptedList)
        let orderedNumbers = interruptedBlocks.compactMap { block -> [Int]? in
            if case let .orderedList(items) = block { return items.map(\.number) }
            return nil
        }
        precondition(orderedNumbers == [[1], [2], [3]], "Expected ordered numbers to follow the source even when interrupted by paragraphs")

        // Regression: AI answers frequently include GFM tables; they must parse
        // into a dedicated table block instead of raw pipe-text paragraphs,
        // and the parser must keep scanning after the table.
        let tableMarkdown = """
        | 概念 | 含义 | 例子 |
        | --- | --- | --- |
        | 进程 | 运行中的程序 | `ps` |
        | 线程 | 进程内的执行流 | pthread |

        表格之后还有正文。
        """
        let tableBlocks = LearningMarkdownParser.parse(tableMarkdown)
        precondition(
            tableBlocks.contains(.table(
                headers: ["概念", "含义", "例子"],
                rows: [["进程", "运行中的程序", "`ps`"], ["线程", "进程内的执行流", "pthread"]]
            )),
            "Expected GFM table parsing"
        )
        precondition(tableBlocks.contains(.paragraph("表格之后还有正文。")), "Expected parsing to continue after a table")

        // Regression: `- [ ]` / `- [x]` task lines must become a task list,
        // not plain unordered bullets.
        let taskMarkdown = """
        - [x] 已读第一章
        - [ ] 做课后题
        """
        let taskBlocks = LearningMarkdownParser.parse(taskMarkdown)
        precondition(
            taskBlocks.contains(.taskList([
                LearningTaskItem(checked: true, text: "已读第一章"),
                LearningTaskItem(checked: false, text: "做课后题")
            ])),
            "Expected task list parsing"
        )

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
                expectsWebSearch: true,
                expectedHistoryTurnCount: 0
            )
        ).explain(request: "解释这一页", pageIndex: 2)
        precondition(apiResponse.text == "fixture explanation", "Expected Responses API output text")
        precondition(apiResponse.sourceKind == .web, "Expected web source label when citations are returned")
        precondition(apiResponse.citations.first?.url.absoluteString == "https://example.com/source", "Expected URL citation")

        let selectionResponse = await QwenLearningAssistant(
            apiKey: "fixture-key",
            pageContent: .text("fixture page text"),
            selectionText: "文件系统在不同操作系统中有不同的结构",
            transport: FixtureAssistantTransport(
                expectedEndpoint: "https://dashscope.aliyuncs.com/compatible-mode/v1/responses",
                expectedModelID: "qwen3.8-max",
                expectedImageCount: 0,
                expectsWebSearch: false,
                expectedHistoryTurnCount: 0,
                expectsSelectionText: true
            )
        ).explain(request: "用更简单的话解释", pageIndex: 2)
        precondition(selectionResponse.text == "fixture explanation", "Expected selected-passage output text")

        let imageResponse = await QwenLearningAssistant(
            apiKey: "fixture-key",
            apiHost: URL(string: "https://workspace.cn-beijing.maas.aliyuncs.com/compatible-mode/v1/")!,
            modelID: "qwen3.7-plus",
            pageContent: .imageJPEG(Data([0xFF, 0xD8, 0xFF])),
            transport: FixtureAssistantTransport(
                expectedEndpoint: "https://workspace.cn-beijing.maas.aliyuncs.com/compatible-mode/v1/responses",
                expectedModelID: "qwen3.7-plus",
                expectedImageCount: 1,
                expectsWebSearch: false,
                expectedHistoryTurnCount: 0,
                expectsPageContent: false
            )
        ).explain(request: "解释扫描页", pageIndex: 4)
        precondition(imageResponse.text == "fixture explanation", "Expected scanned-page output text")

        let streamingAssistant = QwenLearningAssistant(
            apiKey: "fixture-key",
            pageContent: .text("fixture page text"),
            additionalImagesJPEG: [Data([0xFF, 0xD8, 0xFF])],
            conversationContext: [
                .init(question: "之前的问题", answer: "之前的回答")
            ],
            allowsWebSearch: true,
            transport: FixtureAssistantTransport(
                expectedEndpoint: "https://dashscope.aliyuncs.com/compatible-mode/v1/responses",
                expectedModelID: "qwen3.8-max",
                expectedImageCount: 1,
                expectsWebSearch: true,
                expectedHistoryTurnCount: 1
            )
        )
        var streamUpdates: [LearningResponse] = []
        for await update in streamingAssistant.streamExplain(request: "结合附图解释", pageIndex: 5) {
            streamUpdates.append(update)
        }
        precondition(streamUpdates.first?.text == "fixture ", "Expected first streaming text delta")
        precondition(streamUpdates.last?.text == "fixture explanation", "Expected assembled streaming response")
        precondition(streamUpdates.last?.citations.first?.url.absoluteString == "https://example.com/source", "Expected final streaming citations")

        // 不带页上下文的提问：请求里不得夹带「正在阅读第 N 页」的页面内容，
        // 也不能把 nil 页面当成图片发送。
        let bareQuestion = await QwenLearningAssistant(
            apiKey: "fixture-key",
            pageContent: nil,
            transport: FixtureAssistantTransport(
                expectedEndpoint: "https://dashscope.aliyuncs.com/compatible-mode/v1/responses",
                expectedModelID: "qwen3.8-max",
                expectedImageCount: 0,
                expectsWebSearch: false,
                expectedHistoryTurnCount: 0,
                expectsPageContent: false
            )
        ).explain(request: "解释一下这个概念", pageIndex: 3)
        precondition(bareQuestion.text == "fixture explanation", "Expected no-context question to still answer")

        // 上下文范围持久化：新枚举可编码往返，旧存档（缺字段）解码为 nil，
        // 不能因为新增字段而让整本书的学习记录读不出来。
        let scopes: [LearningContextScope] = [
            .none,
            .page,
            .pageRange(start: 2, end: 5),
            .wholeDocument
        ]
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for scope in scopes {
            let data = try encoder.encode(scope)
            let decoded = try decoder.decode(LearningContextScope.self, from: data)
            precondition(decoded == scope, "Expected context scope Codable round-trip")
        }
        let legacyTurnJSON = """
        {
          "id": "\(UUID().uuidString)",
          "question": "旧问题",
          "answer": "旧答案",
          "pageIndex": 1,
          "sourceKind": "currentPDF",
          "citations": [],
          "attachmentCount": 0,
          "createdAt": 1750000000,
          "completion": "completed"
        }
        """
        let legacyTurn = try decoder.decode(LearningTurn.self, from: Data(legacyTurnJSON.utf8))
        precondition(legacyTurn.contextScope == nil, "Expected legacy turns to decode without contextScope")
        precondition(legacyTurn.responseDuration == nil, "Expected legacy turns to decode without responseDuration")
        precondition(legacyTurn.selectionText == nil, "Expected legacy turns to decode without selectionText")
        precondition(legacyTurn.selectionOffset == nil, "Expected legacy turns to decode without selectionOffset")
        let timedTurn = LearningTurn(
            question: "带耗时的问答",
            answer: "回答",
            pageIndex: 0,
            sourceKind: .currentPDF,
            contextScope: .pageRange(start: 1, end: 3),
            responseDuration: 4.2,
            selectionText: "被选中的原文",
            selectionOffset: 0.42
        )
        let timedRoundTrip = try decoder.decode(LearningTurn.self, from: encoder.encode(timedTurn))
        precondition(timedRoundTrip.contextScope == .pageRange(start: 1, end: 3), "Expected context scope to persist")
        precondition(abs((timedRoundTrip.responseDuration ?? -1) - 4.2) < 0.001, "Expected response duration to persist")
        precondition(timedRoundTrip.selectionText == "被选中的原文", "Expected selected passage to persist for retry")
        precondition(abs((timedRoundTrip.selectionOffset ?? -1) - 0.42) < 0.001, "Expected selected passage position to persist")

        let clampedTurn = LearningTurn(
            question: "边界位置",
            answer: "回答",
            pageIndex: 0,
            sourceKind: .currentPDF,
            selectionOffset: 2
        )
        precondition(clampedTurn.selectionOffset == 1, "Expected selection offset to clamp to the page bottom")

        // Glyph-positioned PDFs hand back CJK text with a space wedged between
        // every character ("返 回 正 整 数"). Those spaces are always artifacts
        // and must be dropped before the text becomes preview or model input.
        precondition(
            ExtractedTextNormalizer.normalize("返 回 正 整 数 n u m 的 位 数") == "返回正整数 n u m 的位数",
            "Expected inter-CJK spaces to collapse while Latin runs stay intact"
        )
        precondition(
            ExtractedTextNormalizer.normalize("定 义 函 数 isHuiWenShu") == "定义函数 isHuiWenShu",
            "Expected a CJK-to-Latin boundary space to survive"
        )
        precondition(
            ExtractedTextNormalizer.normalize("length=10; /*设 定 num 的 位 数*/") == "length=10; /*设定 num 的位数*/",
            "Expected code spacing to survive while CJK runs collapse"
        )
        precondition(
            ExtractedTextNormalizer.normalize("第 一 步。 第 二 步") == "第一步。第二步",
            "Expected CJK punctuation to bridge a collapse"
        )
        precondition(
            ExtractedTextNormalizer.normalize("  正常中文句子，不该被改。  ") == "正常中文句子，不该被改。",
            "Expected clean CJK text to only be trimmed"
        )

        // Code runner: an answer's example snippet can be executed locally.
        let pythonRun = await CodeRunner.run(
            code: "print('hello from satori')",
            language: .python
        )
        precondition(pythonRun.exitCode == 0, "Expected python run to succeed")
        precondition(pythonRun.stdout.contains("hello from satori"), "Expected python stdout to be captured")
        precondition(pythonRun.timedOut == false, "Expected quick python run to not time out")

        let cCode = """
        #include <stdio.h>
        int main(void) { printf("%d\\n", 6 * 7); return 0; }
        """
        let cRun = await CodeRunner.run(code: cCode, language: .c)
        // Write diagnostics to a file: a failed `precondition` aborts before
        // stdout flushes, so print() alone loses the details.
        let probeFile = FileManager.default.temporaryDirectory.appending(path: "satori-c-probe-\(UUID().uuidString).txt")
        try? """
        C exit: \(cRun.exitCode)
        C stdout: [\(cRun.stdout)]
        C stderr: [\(cRun.stderr)]
        C timedOut: \(cRun.timedOut)
        C source first line: [\(cCode.components(separatedBy: "\n").first ?? "?")]
        C source byte count: \(cCode.utf8.count)
        """.write(to: probeFile, atomically: true, encoding: .utf8)
        precondition(cRun.exitCode == 0, "Expected C compile+run to succeed")
        precondition(cRun.stdout.contains("42"), "Expected C program output to be captured")

        let timeoutRun = await CodeRunner.run(
            code: "import time\nwhile True:\n    time.sleep(1)",
            language: .python,
            configuration: .init(timeout: 1, outputLimit: 16_000)
        )
        precondition(timeoutRun.timedOut, "Expected runaway loop to be killed by the timeout")

        let outputLimitRun = await CodeRunner.run(
            code: "for i in range(10000):\n    print(i)",
            language: .python,
            configuration: .init(timeout: 8, outputLimit: 1_000)
        )
        precondition(outputLimitRun.stdout.count <= 1_100, "Expected stdout to be capped")

        // Review questions: parser handles fenced, bulleted, varied output.
        let parsedQuestions = ReviewQuestionParser.parse("""
        ```text
        - 什么是进程？ | 运行中的程序实例，包含代码、数据和资源。
        - 什么是死锁？ | 多个进程互相等待对方占用的资源而无法推进。
        3. 什么是系统调用？ | 应用程序请求内核服务的接口。
        ```
        """, pageIndex: 5)
        precondition(parsedQuestions.count == 3, "Expected three parsed review questions")
        precondition(parsedQuestions.allSatisfy { $0.pageIndex == 5 }, "Expected page index attached")
        precondition(parsedQuestions[0].question == "什么是进程？", "Expected question text parsed")

        // Review store: saves, lists due, and advances spacing on rating.
        let reviewFile = root.appending(path: "review-questions.json")
        let reviewStore = ReviewStore(fileURL: reviewFile)
        let docID = UUID()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let q = ReviewQuestion(question: "Q", answer: "A", pageIndex: 1, createdAt: now, dueAt: now)
        try await reviewStore.save([q], for: docID)
        var due = try await reviewStore.dueQuestions(for: docID, now: now)
        precondition(due.count == 1, "Expected newly created question to be due")

        // SM-2 scheduling: "good" grows the interval 1 → 2 → 4 → 8 days by the
        // consecutive-good streak, "hard" trails one step behind, and "again"
        // resets the streak and interval to 1 day.
        var question = try XCTUnwrap(try await reviewStore.questions(for: docID).first)
        precondition(question.consecutiveGoodCount == 0, "Expected a fresh question to start with no good streak")
        precondition(question.lastIntervalDays == 0, "Expected a fresh question to start with no interval")

        func dueDate(_ days: Double, after base: Date) -> Date {
            base.addingTimeInterval(days * 86_400)
        }

        // First "good": interval 1 day → due at day 1, streak 1.
        try await reviewStore.rate(for: docID, question: question, rating: .good, now: now)
        question = try XCTUnwrap(try await reviewStore.questions(for: docID).first)
        precondition(question.dueAt == dueDate(1, after: now), "Expected first good rating to schedule 1 day out")
        precondition(question.consecutiveGoodCount == 1, "Expected good streak to advance to 1")
        precondition(question.lastIntervalDays == 1, "Expected last interval to be 1 day")
        due = try await reviewStore.dueQuestions(for: docID, now: now)
        precondition(due.isEmpty, "Expected rated-good question to no longer be due now")

        // Second "good": interval 2 days → due at day 3, streak 2.
        try await reviewStore.rate(for: docID, question: question, rating: .good, now: dueDate(1, after: now))
        question = try XCTUnwrap(try await reviewStore.questions(for: docID).first)
        precondition(question.dueAt == dueDate(3, after: now), "Expected second good rating to schedule 2 days out")
        precondition(question.consecutiveGoodCount == 2, "Expected good streak to advance to 2")
        precondition(question.lastIntervalDays == 2, "Expected last interval to be 2 days")

        // Third "good": interval 4 days → due at day 7, streak 3.
        try await reviewStore.rate(for: docID, question: question, rating: .good, now: dueDate(3, after: now))
        question = try XCTUnwrap(try await reviewStore.questions(for: docID).first)
        precondition(question.dueAt == dueDate(7, after: now), "Expected third good rating to schedule 4 days out")
        precondition(question.consecutiveGoodCount == 3, "Expected good streak to advance to 3")
        precondition(question.lastIntervalDays == 4, "Expected last interval to be 4 days")

        // "hard" at streak 3: interval 4 days — one step behind the next good's 8.
        try await reviewStore.rate(for: docID, question: question, rating: .hard, now: dueDate(7, after: now))
        question = try XCTUnwrap(try await reviewStore.questions(for: docID).first)
        precondition(question.dueAt == dueDate(11, after: now), "Expected hard rating to schedule 4 days out")
        precondition(question.consecutiveGoodCount == 3, "Expected hard rating to preserve the good streak")
        precondition(question.lastIntervalDays == 4, "Expected hard interval to stay one step behind good")

        // "again" resets the streak and the interval to 1 day.
        try await reviewStore.rate(for: docID, question: question, rating: .again, now: dueDate(11, after: now))
        question = try XCTUnwrap(try await reviewStore.questions(for: docID).first)
        precondition(question.dueAt == dueDate(12, after: now), "Expected again rating to reset to 1 day out")
        precondition(question.consecutiveGoodCount == 0, "Expected again rating to reset the good streak")
        precondition(question.lastIntervalDays == 1, "Expected again rating to reset the interval to 1 day")
        due = try await reviewStore.dueQuestions(for: docID, now: dueDate(11.5, after: now))
        precondition(due.isEmpty, "Expected rated question to stay hidden until its new due date")

        // Gamification: streaks, progress, and badges from real behavior.
        let statsFile = root.appending(path: "learning-stats.json")
        let statsStore = LearningStatsStore(fileURL: statsFile)
        let statsDoc = UUID()
        let day1 = Calendar.current.startOfDay(for: .now)
        let day2 = Calendar.current.date(byAdding: .day, value: 1, to: day1)!
        let day3 = Calendar.current.date(byAdding: .day, value: 2, to: day1)!

        try await statsStore.recordPageRead(documentID: statsDoc, pageIndex: 0, pageCount: 5, on: day1)
        try await statsStore.recordQuestion(documentID: statsDoc, on: day1)
        var stats = try await statsStore.current()
        precondition(stats.streakDays == 1, "Expected day-1 streak to start at 1")
        precondition(stats.unlockedBadges.contains(.firstQuestion), "Expected first-question badge")
        precondition(stats.unlockedBadges.contains(.firstCodeRun) == false, "Expected no code badge yet")

        // Same day activity doesn't bump the streak; next day does.
        try await statsStore.recordQuestion(documentID: statsDoc, on: day1)
        stats = try await statsStore.current()
        precondition(stats.streakDays == 1, "Expected same-day activity to keep streak at 1")

        try await statsStore.recordCodeRun(documentID: statsDoc, on: day2)
        try await statsStore.recordPageRead(documentID: statsDoc, pageIndex: 1, pageCount: 5, on: day3)
        stats = try await statsStore.current()
        precondition(stats.streakDays == 3, "Expected three consecutive days")
        precondition(stats.unlockedBadges.contains(.threeDayStreak), "Expected 3-day streak badge")

        // Reading all pages of the book → 100% progress + first-book badge.
        for page in 0..<5 {
            try await statsStore.recordPageRead(documentID: statsDoc, pageIndex: page, pageCount: 5, on: day3)
        }
        stats = try await statsStore.current()
        let docActivity = stats.documentCounts[statsDoc]!
        precondition(docActivity.progress == 1.0, "Expected 100% progress after reading every page")
        precondition(stats.unlockedBadges.contains(.firstBook), "Expected first-book badge")

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
    let expectedHistoryTurnCount: Int
    var expectsPageContent: Bool = true
    var expectsSelectionText: Bool = false

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
        precondition(input.count == expectedHistoryTurnCount * 2 + 1, "Expected bounded conversation messages before the current question")
        if expectedHistoryTurnCount > 0 {
            precondition(input.first?["role"] as? String == "user", "Expected prior user message")
            precondition(input.dropFirst().first?["role"] as? String == "assistant", "Expected prior assistant message")
            let assistantContent = try XCTUnwrap(input.dropFirst().first?["content"] as? [[String: Any]])
            precondition(assistantContent.first?["type"] as? String == "output_text", "Expected prior answer output content")
        }
        let content = try XCTUnwrap(input.last?["content"] as? [[String: Any]])
        let pageText = content.filter { $0["type"] as? String == "input_text" }
            .compactMap { $0["text"] as? String }
            .first { $0.hasPrefix("用户正在阅读教材 PDF") }
        precondition((pageText != nil) == expectsPageContent, "Expected page content presence to match scope")
        let selectionText = content.filter { $0["type"] as? String == "input_text" }
            .compactMap { $0["text"] as? String }
            .first { $0.hasPrefix("用户在 PDF 中选中的原文") }
        precondition((selectionText != nil) == expectsSelectionText, "Expected selected passage presence to match request")
        if expectsSelectionText {
            precondition(selectionText?.contains("文件系统在不同操作系统中有不同的结构") == true, "Expected selected passage to be preserved as a separate input")
        }
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
