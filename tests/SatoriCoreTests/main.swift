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
        precondition(
            QwenLearningAssistant.shouldAutoEnableWebSearch(for: "openEuler 的资料给我找找"),
            "Expected explicit material lookup to route to web search"
        )
        precondition(
            QwenLearningAssistant.shouldAutoEnableWebSearch(for: "这个版本有没有过时"),
            "Expected freshness question to route to web search"
        )
        precondition(
            !QwenLearningAssistant.shouldAutoEnableWebSearch(for: "这一页最重要的一个意思是什么？"),
            "Expected normal page understanding to stay PDF-local"
        )
        precondition(
            QwenLearningAssistant.shouldAutoEnableWebSearch(for: "这里面的知识过时了么"),
            "Expected colloquial freshness questions to route to web search"
        )
        precondition(
            QwenLearningAssistant.shouldAutoEnableWebSearch(for: "今日金价"),
            "Expected explicit live-price questions to route to web search"
        )
        precondition(
            !QwenLearningAssistant.shouldAutoEnableWebSearch(for: "这个价格公式怎么推出来的"),
            "Expected ordinary textbook price questions to stay PDF-local"
        )
        precondition(
            QwenLearningAssistant.defaultLearningInstructions.contains("不要把教材里的旧信息冒充当前事实"),
            "Expected live web answers to be separated from stale textbook facts"
        )
        precondition(
            QwenLearningAssistant.defaultLearningInstructions.contains("不要无依据地推断作者意图"),
            "Expected textbook criticism to stay grounded in page evidence"
        )
        precondition(
            QwenLearningAssistant.defaultLearningInstructions.contains("快速阅读地图"),
            "Expected book and chapter overviews to produce a reading map"
        )
        precondition(
            QwenLearningAssistant.defaultLearningInstructions.contains("可能只是 OCR/排版问题"),
            "Expected textbook correctness checks to separate OCR doubts from factual errors"
        )
        precondition(
            ReadingOCRPolicy.usesRemoteOCR(forPageRangeCount: 2, hasQwenConfiguration: true),
            "Expected short page bridges to use high-fidelity remote OCR"
        )
        precondition(
            !ReadingOCRPolicy.usesRemoteOCR(forPageRangeCount: 20, hasQwenConfiguration: true)
                && !ReadingOCRPolicy.usesRemoteOCR(forPageRangeCount: 2, hasQwenConfiguration: false),
            "Expected chapter maps and unconfigured readers to stay local"
        )
        precondition(QwenLearningAssistant.responseTokenBudget(for: "一句话说清楚") == 260, "Expected one-sentence answers to stay compact")
        precondition(
            QwenLearningAssistant.isCompactRequest(for: "简化，字太多")
                && QwenLearningAssistant.responseTokenBudget(for: "简化，字太多") == 420,
            "Expected simplify requests to use a genuinely short reading card"
        )
        precondition(
            QwenLearningAssistant.isQuickClarificationRequest(for: "这啥意思？")
                && QwenLearningAssistant.responseTokenBudget(for: "这啥意思？") == 360,
            "Expected terse reading speed bumps to use a compact clarification path"
        )
        precondition(
            !QwenLearningAssistant.isQuickClarificationRequest(for: "这是什么？请详细展开")
                && QwenLearningAssistant.responseTokenBudget(for: "这是什么？请详细展开") == 1_400,
            "Expected explicit depth requests to keep the normal answer budget"
        )
        precondition(
            ReadingPagePurpose.isExercisePage("习题\n1. 什么是文件系统？\n2. 目录有什么作用？"),
            "Expected a headed exercise page to switch to exercise reading mode"
        )
        precondition(
            ReadingPagePurpose.isExercisePage("9. 请设计一个目录结构。\n10. 假定磁盘块大小为 512 字节，计算访问次数。\n11. 说明文件共享方法。\n12. 为什么要控制权限？"),
            "Expected a continued exercise page to switch to exercise reading mode"
        )
        precondition(
            !ReadingPagePurpose.isExercisePage("本书配有习题册和错题本，读者可以课后练习。"),
            "Expected a passing mention of exercises in prose to stay ordinary"
        )
        precondition(QwenLearningAssistant.responseTokenBudget(for: "我刚开始读这一章，请给我阅读路线图") == 900, "Expected reading maps to keep enough room for structure")
        precondition(QwenLearningAssistant.responseTokenBudget(for: "解释这一页") == 1_400, "Expected ordinary explanations to keep the normal budget")
        precondition(QwenLearningAssistant.responseTokenBudget(for: "解释我选中的这段内容", hasSelection: true) == 700, "Expected selected-passage explanations to stay compact by default")
        precondition(QwenLearningAssistant.responseTokenBudget(for: "完整代码", hasSelection: true) == 1_400, "Expected explicit complete-code requests to keep enough room")
        // Real system.pdf outline: Chapter 6 starts at PDF page 183 (index 182)
        // and Chapter 7 starts at PDF page 228 (index 227).
        precondition(
            ReadingFactAnswer.pageCountAnswer(
                for: "这一章有多少页",
                pageCount: 294,
                currentPageIndex: 187,
                scope: .page,
                chapterRange: 182...227
            ) == "当前范围是第 183–228 页，共 46 页。",
            "Expected the real system.pdf chapter range to include the whole sixth chapter"
        )
        precondition(
            ReadingFactAnswer.pageCountAnswer(
                for: "这本书有多少页",
                pageCount: 294,
                currentPageIndex: 187,
                scope: .page
            ) == "当前范围是第 1–294 页，共 294 页。",
            "Expected whole-book page count to be answered locally"
        )
        precondition(
            ReadingFactAnswer.pageCountAnswer(
                for: "第几页到第几页",
                pageCount: 294,
                currentPageIndex: 187,
                scope: .pageRange(start: 179, end: 181)
            ) == "当前范围是第 180–182 页，共 3 页。",
            "Expected selected page range count to be exact"
        )
        precondition(
            ReadingFactAnswer.pageCountAnswer(
                for: "这一页主要讲什么",
                pageCount: 294,
                currentPageIndex: 187,
                scope: .page
            ) == nil,
            "Expected ordinary understanding requests to stay on the model path"
        )
        precondition(
            ReadingScopeInference.scope(
                for: "这一章在讲什么",
                pageIndex: 187,
                chapterRange: 182...227,
                sectionRange: 182...188
            ) == .pageRange(start: 182, end: 227),
            "Expected chapter language to expand to the current top-level chapter"
        )
        precondition(
            ReadingScopeInference.scope(
                for: "第六章有哪些重点",
                pageIndex: 187,
                chapterRange: 182...227,
                sectionRange: 182...188
            ) == .pageRange(start: 182, end: 227),
            "Expected numbered chapter language to expand naturally"
        )
        precondition(
            ReadingScopeInference.scope(
                for: "这本书主要讲什么",
                pageIndex: 187,
                chapterRange: 182...227,
                sectionRange: 182...188
            ) == .wholeDocument,
            "Expected book-overview language to use the whole document"
        )
        precondition(
            ReadingScopeInference.scope(
                for: "这本书难吗？",
                pageIndex: 30,
                chapterRange: 0...28,
                sectionRange: 20...28
            ) == .wholeDocument,
            "Expected book difficulty questions to use the whole document"
        )
        precondition(
            ReadingScopeInference.scope(
                for: "这本书有没有过时的内容？",
                pageIndex: 30,
                chapterRange: 0...28,
                sectionRange: 20...28
            ) == .wholeDocument,
            "Expected book freshness questions to use the whole document"
        )
        precondition(
            ReadingScopeInference.scope(
                for: "这本书第几页有磁盘内容",
                pageIndex: 187,
                chapterRange: 182...227,
                sectionRange: 182...188
            ) == nil,
            "Expected a book page lookup not to trigger whole-book context"
        )
        precondition(
            ReadingScopeInference.scope(
                for: "上一页和这一页怎么连起来",
                pageIndex: 187,
                chapterRange: 182...227,
                sectionRange: 182...188
            ) == .pageRange(start: 186, end: 187),
            "Expected previous-page language to include the adjacent page"
        )
        precondition(
            ReadingScopeInference.scope(
                for: "这一页接着前面的文件系统内容往下讲了什么",
                pageIndex: 187,
                chapterRange: 182...227,
                sectionRange: 182...188
            ) == .pageRange(start: 186, end: 187),
            "Expected natural continuation language to include the adjacent page"
        )
        precondition(
            ReadingScopeInference.scope(
                for: "这一页和前面有什么关系",
                pageIndex: 187,
                chapterRange: 182...227,
                sectionRange: 182...188
            ) == .pageRange(start: 186, end: 187),
            "Expected relationship language to include the adjacent page"
        )
        precondition(
            ReadingScopeInference.scope(
                for: "这一页和刚才讲的有什么关系",
                pageIndex: 187,
                chapterRange: 182...227,
                sectionRange: 182...188
            ) == .pageRange(start: 186, end: 187),
            "Expected colloquial '刚才' relationship language to include the adjacent page"
        )
        precondition(
            ReadingScopeInference.scope(
                for: "这一页的磁盘地址是什么意思",
                pageIndex: 187,
                chapterRange: 182...227,
                sectionRange: 182...188
            ) == nil,
            "Expected ordinary page questions to keep the default page scope"
        )
        precondition(
            ReadingScopeInference.inheritsRecentScope(for: "有多少页"),
            "Expected terse page-count follow-ups to inherit the recent reading scope"
        )
        precondition(
            ReadingScopeInference.inheritsRecentScope(for: "有什么值得看的"),
            "Expected terse priority follow-ups to inherit the recent reading scope"
        )
        precondition(
            ReadingScopeInference.inheritsRecentScope(for: "那有没有过时的内容"),
            "Expected freshness follow-ups to inherit the recent reading scope"
        )
        precondition(
            ReadingScopeInference.isRecentScopeRelevant(
                .pageRange(start: 10, end: 20),
                turnPageIndex: 12,
                currentPageIndex: 18
            ) && !ReadingScopeInference.isRecentScopeRelevant(
                .pageRange(start: 10, end: 20),
                turnPageIndex: 12,
                currentPageIndex: 21
            ),
            "Expected chapter follow-ups to stop inheriting after a chapter jump"
        )
        precondition(
            ReadingScopeInference.isRecentScopeRelevant(
                .wholeDocument,
                turnPageIndex: 12,
                currentPageIndex: 291
            ) && !ReadingScopeInference.isRecentScopeRelevant(
                .page,
                turnPageIndex: 12,
                currentPageIndex: 13
            ),
            "Expected whole-book scope to survive navigation but page scope not to"
        )
        precondition(
            ReadingScopeInference.scope(
                for: "下一页讲什么？",
                pageIndex: 10,
                chapterRange: 0...20,
                sectionRange: 10...12,
                pageCount: 40
            ) == .pageRange(start: 10, end: 11),
            "Expected forward-looking questions to include the next page"
        )
        precondition(
            ReadingScopeInference.scope(
                for: "然后呢",
                pageIndex: 39,
                chapterRange: 0...39,
                sectionRange: nil,
                pageCount: 40
            ) == .pageRange(start: 39, end: 39),
            "Expected next-page scope to stop at the end of a book"
        )
        precondition(
            ChapterNumberParser.number(in: "第六章") == 6
                && ChapterNumberParser.number(in: "第6章 文件系统") == 6
                && ChapterNumberParser.number(in: "第六节", unit: "节") == 6
                && ChapterNumberParser.number(in: "第十二章") == 12,
            "Expected Arabic and Chinese chapter markers to resolve identically"
        )
        let scannedOutline = ScannedOutlineParser.parse(lines: [
            "第一章 概述................25",
            "第一节 计算机发展...........25",
            "第二章 C语言基础知识........43",
            "第十章 文件与综合练习.......308"
        ])
        precondition(
            scannedOutline == [
                ScannedOutlineEntry(chapterNumber: 1, title: "概述", printedPage: 25),
                ScannedOutlineEntry(chapterNumber: 2, title: "C语言基础知识", printedPage: 43),
                ScannedOutlineEntry(chapterNumber: 10, title: "文件与综合练习", printedPage: 308)
            ],
            "Expected scanned table-of-contents chapter lines to parse without sections"
        )
        let scannedHierarchy = ScannedOutlineParser.parseHierarchy(lines: [
            "第一章 概述................25",
            "第一节 函数的概念和模块化程序",
            "设计•178",
            "第二节 函数声明•185",
            "第二章 C语言基础知识•200"
        ])
        precondition(
            scannedHierarchy.contains {
                $0.depth == 1
                    && $0.chapterNumber == 1
                    && $0.sectionNumber == 1
                    && $0.title == "函数的概念和模块化程序设计"
                    && $0.printedPage == 178
            },
            "Expected wrapped scanned section headings to keep chapter and page metadata"
        )
        let realLanguageTOC = ScannedOutlineParser.parseHierarchy(lines: [
            "第一章 概述 ：25",
            "第一节 计算机发展 ：25",
            "第二节 计算机语言 •26",
            "第三节 算法及其描述方法• ：27",
            "第六章 函数 178",
            "第一节 函数的概念和模块化程序",
            "设计• 178",
            "第二节 函数声明• •185"
        ])
        precondition(
            realLanguageTOC.contains {
                $0.depth == 1 && $0.chapterNumber == 6 && $0.sectionNumber == 2
                    && $0.title == "函数声明" && $0.printedPage == 185
            },
            "Expected real language-textbook TOC OCR lines to preserve section order"
        )
        let noisyScannedOutline = ScannedOutlineParser.parse(lines: [
            "第一章 概述 ：25",
            "第二章 C语言基础知识• •43",
            "第三章 数据类型、运算符和表达式 ⋯60",
            "第十章 文件⋯ •308"
        ])
        precondition(
            noisyScannedOutline.count == 4 && noisyScannedOutline[0].title == "概述",
            "Expected OCR punctuation and spaces to stay parseable"
        )
        let softwareScannedOutline = ScannedOutlineParser.parse(lines: [
            "第六章 软件维护 184",
            "第七章 ：软件项目管理 201"
        ])
        precondition(
            softwareScannedOutline.map(\.title) == ["软件维护", "软件项目管理"],
            "Expected real software-textbook OCR punctuation to be trimmed"
        )
        precondition(
            !ReadingScopeInference.inheritsRecentScope(for: "这一页主要讲什么"),
            "Expected ordinary explanations not to inherit a stale scope"
        )
        precondition(
            ReadingVisualEvidence.requiresPageImage(currentText: "磁盘结构如图 6-2 所示"),
            "Expected a page that names a figure to carry visual evidence"
        )
        precondition(
            ReadingVisualEvidence.mentionsVisualReference(in: "磁盘的结构如图6-2所示。"),
            "Expected a current-page figure reference to request a look-ahead image"
        )
        precondition(
            ReadingVisualEvidence.requiresPageImage(
                currentText: "单张磁盘外表看起来就像一张唱片",
                previousText: "磁盘的结构如图6-2所示。"
            ),
            "Expected a figure that starts on the next page to carry the next page image"
        )
        precondition(
            ReadingVisualEvidence.requiresPageImage(
                currentText: "",
                previousText: "",
                nativePageText: ""
            ),
            "Expected an OCR-missed scan page to keep its original image in a short bridge"
        )
        precondition(
            !ReadingVisualEvidence.requiresPageImage(
                currentText: "文件系统负责存储、检索和更新",
                previousText: "",
                nativePageText: "文件系统负责存储、检索和更新。磁盘和文件目录共同提供稳定的访问接口，并支持按名称查找、按地址定位以及对内容进行修改。"
            ),
            "Expected ordinary native-text bridge pages to remain text-only"
        )
        precondition(
            !ReadingVisualEvidence.requiresPageImage(currentText: "文件系统负责存储、检索和更新"),
            "Expected ordinary prose to stay text-only"
        )
        precondition(
            !ReadingVisualEvidence.mentionsVisualReference(in: "文件系统负责存储、检索和更新"),
            "Expected ordinary prose not to trigger a look-ahead image"
        )
        let representativePages = ReadingSamplePlan.representativePageIndices(
            pageCount: 294,
            outlinePageIndices: [29, 31, 64, 92, 117, 145, 182, 228, 260],
            excluding: Set([29, 30])
        )
        precondition(representativePages.contains(182), "Expected whole-book sampling to include a late chapter start")
        precondition(representativePages.contains(293), "Expected whole-book sampling to include the final page")
        precondition(!representativePages.contains(29), "Expected the reading neighborhood to stay in its stronger OCR pass")
        let chapterMapPages = ReadingSamplePlan.representativePageIndices(
            in: 182...227,
            outlinePageIndices: [182, 189, 196, 206, 210, 211, 214, 218, 223, 225, 228]
        )
        precondition(chapterMapPages.contains(182) && chapterMapPages.contains(227), "Expected chapter maps to keep both boundaries")
        precondition(chapterMapPages.contains(189) && chapterMapPages.contains(218), "Expected chapter maps to keep outline anchors inside the range")
        precondition(chapterMapPages.count <= 16, "Expected chapter maps to respect the sampling budget")
        precondition(
            ReadingSamplePlan.representativeImagePageIndices(from: chapterMapPages) == [182, 206],
            "Expected scanned chapter routes to keep only opening and middle visual samples"
        )
        precondition(
            ReadingSamplePlan.representativeImagePageIndices(from: [4], maxCount: 2) == [4],
            "Expected a one-page chapter route to keep its only visual sample"
        )

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
                expectsSelectionText: true,
                expectedMaxOutputTokens: 700
            )
        ).explain(request: "解释我选中的这段内容", pageIndex: 2)
        precondition(selectionResponse.text == "fixture explanation", "Expected selected-passage output text")

        let quickClarificationResponse = await QwenLearningAssistant(
            apiKey: "fixture-key",
            pageContent: .text("fixture page text"),
            selectionText: "文件系统在不同操作系统中有不同的结构",
            transport: FixtureAssistantTransport(
                expectedEndpoint: "https://dashscope.aliyuncs.com/compatible-mode/v1/responses",
                expectedModelID: "qwen3.8-max",
                expectedImageCount: 0,
                expectsWebSearch: false,
                expectedHistoryTurnCount: 0,
                expectsSelectionText: true,
                expectsQuickClarification: true,
                expectedMaxOutputTokens: 360
            )
        ).explain(request: "这啥意思？", pageIndex: 2)
        precondition(quickClarificationResponse.text == "fixture explanation", "Expected terse clarification output path")

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

        let figurePageResponse = await QwenLearningAssistant(
            apiKey: "fixture-key",
            pageContent: .textAndImages(
                "【第 187 页】磁盘由磁道、扇区和磁头定位。",
                [.init(pageIndex: 186, jpegData: Data([0xFF, 0xD8, 0xFF]))]
            ),
            transport: FixtureAssistantTransport(
                expectedEndpoint: "https://dashscope.aliyuncs.com/compatible-mode/v1/responses",
                expectedModelID: "qwen3.8-max",
                expectedImageCount: 1,
                expectsWebSearch: false,
                expectedHistoryTurnCount: 0,
                expectsPageContent: true,
                expectsVisualEvidenceInstruction: true
            )
        ).explain(request: "结合图示解释磁盘地址", pageIndex: 186)
        precondition(figurePageResponse.text == "fixture explanation", "Expected figure-aware page content to reach the model")

        let degradedTextResponse = await QwenLearningAssistant(
            apiKey: "fixture-key",
            pageContent: .textAndImage(
                "文字层里有疑似 OCR 错误的术语",
                Data([0xFF, 0xD8, 0xFF])
            ),
            transport: FixtureAssistantTransport(
                expectedEndpoint: "https://dashscope.aliyuncs.com/compatible-mode/v1/responses",
                expectedModelID: "qwen3.8-max",
                expectedImageCount: 1,
                expectsWebSearch: false,
                expectedHistoryTurnCount: 0,
                expectsPageContent: true,
                expectsVisualEvidenceInstruction: true
            )
        ).explain(request: "核对这页的术语", pageIndex: 44)
        precondition(degradedTextResponse.text == "fixture explanation", "Expected damaged text to travel with a page image")

        let exercisePageResponse = await QwenLearningAssistant(
            apiKey: "fixture-key",
            // Real system.pdf: PDF page 226 (printed page 219) starts the
            // file-system exercise section; PDF page 227 continues it.
            pageContent: .text("【第 226 页】\n习 题\n1. 什么是文件系统？\n2. 目录有什么作用？\n3. 假定磁盘块大小，计算访问次数。\n4. 请设计文件权限机制。"),
            transport: FixtureAssistantTransport(
                expectedEndpoint: "https://dashscope.aliyuncs.com/compatible-mode/v1/responses",
                expectedModelID: "qwen3.8-max",
                expectedImageCount: 0,
                expectsWebSearch: false,
                expectedHistoryTurnCount: 0,
                expectsExercisePage: true,
                expectedMaxOutputTokens: 700
            )
        ).explain(request: "这一页主要讲什么？", pageIndex: 225)
        precondition(exercisePageResponse.text == "fixture explanation", "Expected exercise pages to carry a reading-mode hint")

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

        let longConversation = (0..<6).map { (index: Int) in
            LearningConversationContext(
                question: "第 \(index) 轮问题：" + String(repeating: "请解释这个概念。", count: 120),
                answer: String(repeating: "这是上一轮很长的回答，包含原文依据和解释。", count: 420),
                pageIndex: index
            )
        }
        let boundedHistoryResponse = await QwenLearningAssistant(
            apiKey: "fixture-key",
            pageContent: .text("fixture page text"),
            conversationContext: longConversation,
            transport: FixtureAssistantTransport(
                expectedEndpoint: "https://dashscope.aliyuncs.com/compatible-mode/v1/responses",
                expectedModelID: "qwen3.8-max",
                expectedImageCount: 0,
                expectsWebSearch: false,
                expectedHistoryTurnCount: 3,
                maximumRequestBodyBytes: 40_000
            )
        ).explain(request: "继续解释当前页", pageIndex: 6)
        precondition(boundedHistoryResponse.text == "fixture explanation", "Expected long reading history to stay usable")

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

        // 主动验证后的下一条消息必须明确告诉模型：这是用户在作答，
        // 需要判断理解是否成立并指出关键修正，而不是把回答当成普通追问。
        let verificationResponse = await QwenLearningAssistant(
            apiKey: "fixture-key",
            pageContent: .text("fixture page text"),
            isVerificationResponse: true,
            conversationContext: [
                .init(question: "验证一下", answer: "请说说这个概念在实际中怎么用。")
            ],
            transport: FixtureAssistantTransport(
                expectedEndpoint: "https://dashscope.aliyuncs.com/compatible-mode/v1/responses",
                expectedModelID: "qwen3.8-max",
                expectedImageCount: 0,
                expectsWebSearch: false,
                expectedHistoryTurnCount: 1,
                expectsVerificationResponse: true
            )
        ).explain(request: "我觉得它是先保存状态，再根据状态决定下一步。", pageIndex: 2)
        precondition(verificationResponse.text == "fixture explanation", "Expected verification response to use the normal answer path")

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
        precondition(legacyTurn.selectionAnchorOffset == nil, "Expected legacy turns to decode without selectionAnchorOffset")
        let timedTurn = LearningTurn(
            question: "带耗时的问答",
            answer: "回答",
            pageIndex: 0,
            sourceKind: .currentPDF,
            contextScope: .pageRange(start: 1, end: 3),
            responseDuration: 4.2,
            selectionText: "被选中的原文",
            selectionOffset: 0.42,
            selectionAnchorOffset: 0.58
        )
        let timedRoundTrip = try decoder.decode(LearningTurn.self, from: encoder.encode(timedTurn))
        precondition(timedRoundTrip.contextScope == .pageRange(start: 1, end: 3), "Expected context scope to persist")
        precondition(abs((timedRoundTrip.responseDuration ?? -1) - 4.2) < 0.001, "Expected response duration to persist")
        precondition(timedRoundTrip.selectionText == "被选中的原文", "Expected selected passage to persist for retry")
        precondition(abs((timedRoundTrip.selectionOffset ?? -1) - 0.42) < 0.001, "Expected selected passage position to persist")
        precondition(abs((timedRoundTrip.selectionAnchorOffset ?? -1) - 0.58) < 0.001, "Expected precise selection anchor to persist")

        let clampedTurn = LearningTurn(
            question: "边界位置",
            answer: "回答",
            pageIndex: 0,
            sourceKind: .currentPDF,
            selectionOffset: 2
        )
        precondition(clampedTurn.selectionOffset == 1, "Expected selection offset to clamp to the page bottom")

        let invalidPersistedTurnJSON = """
        {
          "id": "\(UUID().uuidString)",
          "question": "越界位置",
          "answer": "回答",
          "pageIndex": -4,
          "sourceKind": "currentPDF",
          "citations": [],
          "attachmentCount": -2,
          "createdAt": 1750000000,
          "completion": "completed",
          "selectionText": "原文",
          "selectionOffset": 2
        }
        """
        let normalizedPersistedTurn = try decoder.decode(
            LearningTurn.self,
            from: Data(invalidPersistedTurnJSON.utf8)
        )
        precondition(normalizedPersistedTurn.pageIndex == 0, "Expected persisted page index to clamp")
        precondition(normalizedPersistedTurn.attachmentCount == 0, "Expected persisted attachment count to clamp")
        precondition(normalizedPersistedTurn.selectionOffset == 1, "Expected persisted selection offset to clamp")

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
        precondition(
            ExtractedTextNormalizer.likelyDegraded(String(repeating: "教材正文 ", count: 8) + "5「。。口叫技术"),
            "Expected obvious OCR punctuation damage to request visual verification"
        )
        precondition(
            !ExtractedTextNormalizer.likelyDegraded(String(repeating: "这是正常的中文教材正文。", count: 8)),
            "Expected clean text to stay text-only"
        )

        precondition(
            CodeRunner.safety(for: "print(2 + 2)", language: .python) == .allowed,
            "Expected pure Python experiments to remain runnable"
        )
        precondition(
            !CodeRunner.safety(for: "import socket\\nprint('network')", language: .python).isAllowed,
            "Expected Python network access to be blocked"
        )
        precondition(
            !CodeRunner.safety(for: "open('outside', 'w').write('x')", language: .python).isAllowed,
            "Expected Python file access to be blocked"
        )
        precondition(
            !CodeRunner.safety(for: "system(\"rm -rf /\");", language: .c).isAllowed,
            "Expected C system execution to be blocked"
        )
        precondition(
            !CodeRunner.safety(
                for: "#include <stdio.h>\nint main(void) { int n; scanf(\"%d\", &n); return n; }",
                language: .c
            ).isAllowed
                && CodeRunner.safety(for: "input('n?')", language: .python).message?.contains("交互输入") == true,
            "Expected interactive stdin examples from textbooks to be blocked with a clear explanation"
        )
        precondition(
            !CodeRunner.safety(for: "echo hello", language: .shell).isAllowed
                && CodeRunner.experimentLanguages == [.python, .c, .cpp],
            "Expected shell not to be offered as an experiment language"
        )
        precondition(
            CodeRunner.languageHint(for: "#include <stdio.h>\nint main(void) { printf(\"hi\"); }") == .c
                && CodeRunner.languageHint(for: "std::cout << 42;") == .cpp
                && CodeRunner.languageHint(for: "print(2 + 2)") == .python
                && CodeRunner.languageHint(for: "这是一段普通教材解释") == nil,
            "Expected conservative language hints for selection-to-experiment routing"
        )

        // Code runner: an answer's example snippet can be executed locally.
        let pythonRun = await CodeRunner.run(
            code: "print('hello from satori')",
            language: .python
        )
        precondition(pythonRun.exitCode == 0, "Expected python run to succeed")
        precondition(pythonRun.stdout.contains("hello from satori"), "Expected python stdout to be captured")
        precondition(pythonRun.timedOut == false, "Expected quick python run to not time out")

        let blockedRun = await CodeRunner.run(
            code: "import socket\\nprint('network')",
            language: .python
        )
        precondition(blockedRun.exitCode != 0 && blockedRun.stderr.contains("实验未运行"), "Expected unsafe experiments to fail closed")

        let interactiveRun = await CodeRunner.run(
            code: "#include <stdio.h>\nint main(void) { int n; scanf(\"%d\", &n); return n; }",
            language: .c
        )
        precondition(
            interactiveRun.exitCode != 0
                && !interactiveRun.timedOut
                && interactiveRun.stderr.contains("交互输入"),
            "Expected textbook stdin examples to fail immediately instead of waiting for input"
        )

        let sandboxedWriteAttempt = await CodeRunner.run(
            code: "import tempfile\\nwith tempfile.NamedTemporaryFile() as handle:\\n    handle.write(b'x')",
            language: .python
        )
        precondition(
            sandboxedWriteAttempt.exitCode != 0 && !sandboxedWriteAttempt.timedOut,
            "Expected the runtime sandbox to deny writes even when a snippet avoids the static gate"
        )

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
    var expectsVerificationResponse: Bool = false
    var expectsQuickClarification: Bool = false
    var expectsExercisePage: Bool = false
    var expectsVisualEvidenceInstruction: Bool = false
    var expectedMaxOutputTokens: Int?
    var maximumRequestBodyBytes: Int?

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
        if let maximumRequestBodyBytes {
            precondition(body.count <= maximumRequestBodyBytes, "Expected conversation history to stay within the request budget")
        }
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        precondition(json["model"] as? String == expectedModelID, "Expected configured Qwen learning model")
        precondition(json["store"] as? Bool == false, "Expected response storage to be disabled")
        precondition(json["stream"] as? Bool == expectsStreaming, "Expected configured streaming mode")
        if let expectedMaxOutputTokens {
            precondition(json["max_output_tokens"] as? Int == expectedMaxOutputTokens, "Expected question-specific output budget")
        }
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
        if expectsVisualEvidenceInstruction {
            precondition(
                (pageText?.contains("页面图像是这页的原始证据") == true
                    || pageText?.contains("页面图像是原始证据") == true)
                    && pageText?.contains("以图像为准") == true
                    && (pageText?.contains("紧邻页") == true
                        || pageText?.contains("下一项页面图像") == true),
                "Expected OCR-backed page requests to prioritize the page image"
            )
        }
        let selectionText = content.filter { $0["type"] as? String == "input_text" }
            .compactMap { $0["text"] as? String }
            .first { $0.hasPrefix("用户在 PDF 中选中的原文") }
        precondition((selectionText != nil) == expectsSelectionText, "Expected selected passage presence to match request")
        if expectsSelectionText {
            precondition(
                selectionText?.contains("文件系统在不同操作系统中有不同的结构") == true
                    && selectionText?.contains("不要用常识补齐") == true,
                "Expected selected passage guidance to reject guessed OCR code completions"
            )
        }
        let verificationMarker = content.filter { $0["type"] as? String == "input_text" }
            .compactMap { $0["text"] as? String }
            .first { $0.hasPrefix("这是用户对上一轮“验证一下”情境的回答") }
        precondition((verificationMarker != nil) == expectsVerificationResponse, "Expected verification response marker to match request")
        let quickClarificationMarker = content.filter { $0["type"] as? String == "input_text" }
            .compactMap { $0["text"] as? String }
            .first { $0.hasPrefix("这是阅读中的一个短卡点") }
        precondition((quickClarificationMarker != nil) == expectsQuickClarification, "Expected terse clarification marker to match request")
        let exerciseMarker = content.filter { $0["type"] as? String == "input_text" }
            .compactMap { $0["text"] as? String }
            .first { $0.hasPrefix("这是教材的习题/题型页") }
        precondition((exerciseMarker != nil) == expectsExercisePage, "Expected exercise pages to use the focused exercise reading stance")
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
