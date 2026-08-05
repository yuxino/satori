import AppKit
import SwiftUI
import SatoriCore
import UniformTypeIdentifiers

struct LearningInspector: View {
    /// The learning panel has three mutually exclusive spaces (⌘1-3): 问 is the
    /// default ask space; 笔记 browses the book's saved Q&A by page; 运行 is the
    /// code scratchpad. Switching modes clears the previous mode's transient
    /// state so nothing leaks.
    enum InspectorMode: String, CaseIterable, Identifiable {
        case ask
        case notes
        case run

        var id: String { rawValue }

        var title: String {
            switch self {
            case .ask: "问"
            case .notes: "笔记"
            case .run: "运行"
            }
        }

        var systemImage: String {
            switch self {
            case .ask: "bubble.left.and.text.bubble.right"
            case .notes: "book.pages"
            case .run: "play.rectangle"
            }
        }

        var shortcut: KeyEquivalent {
            switch self {
            case .ask: "1"
            case .notes: "2"
            case .run: "3"
            }
        }
    }


    /// 提问时参考的上下文：默认不带页上下文，需要时再主动选。
    enum ContextMode: String, CaseIterable, Identifiable {
        case none
        case page
        case chapter
        case pageRange
        case wholeDocument

        var id: String { rawValue }
    }

    let documentID: UUID
    let pageIndex: Int
    let pageCount: Int
    let documentURL: URL
    /// 这本书的章节导览（PDF outline 优先，课程目录回退）；为空时「章节」选项隐藏。
    let chapters: [BookChapter]
    let onNavigateToPage: (Int) -> Void
    let onClose: () -> Void

    @Environment(\.openSettings) private var openSettings
    @Environment(\.scenePhase) private var scenePhase
    @State private var mode: InspectorMode = .ask
    @State private var question = ""
    /// 发送问题时给 AI 的上下文：默认不带上下文（需要时主动选页）。
    @State private var contextMode: ContextMode = .none
    /// 「多页」范围（1 起，UI 显示用；发送时转成 0 起）。
    @State private var rangeStart = 1
    @State private var rangeEnd = 1
    /// 「章节」上下文里用户选中的章节 id；nil 表示跟随当前章节。
    @State private var selectedChapterID: Int?
    /// 上次「问 AI」选中的页码：文本已填入输入框等用户编辑/追问，
    /// 发送时用它锚定上下文；用户翻页或自行改写后失效。
    @State private var pendingSelectionPage: Int?
    @State private var turns: [LearningTurn] = []
    @State private var draftQuestion = ""
    @State private var draftPageIndex = 0
    @State private var draftContextScope: LearningContextScope = .none
    @State private var draftAttachmentCount = 0
    @State private var response: LearningResponse?
    @State private var isThinking = false
    @State private var isLoadingHistory = true
    @State private var historyStatus = ""
    /// 滚动锚点：绑定到列表底部锚点 id 时，内容增长会平滑保持贴底
    /// （ChatGPT 式跟随）；用户上滑看历史时绑定自动脱离，不再打扰。
    @State private var scrollAnchorID: String?
    /// 列表底部是否在视野内；滚上去看历史时变 false，用来显示
    /// 「回到底部」浮动按钮。
    @State private var isAtBottom = true
    @State private var hasQwenConfiguration = false
    @State private var isCheckingConfiguration = false
    @State private var configuredModelID: String?
    @State private var allowsWebSearch = false
    @State private var completedElsewherePage: Int?
    @State private var attachments: [LearningImageAttachment] = []
    /// 发送中的这一轮贴的图（用于对话里即时展示缩略图；归档后历史只记张数）。
    @State private var activeAttachmentPreviews: [NSImage] = []
    @State private var isImportingImage = false
    @State private var attachmentStatus = ""
    /// 这一轮回答开始的时间；用于「过程」脚注里显示耗时。
    @State private var streamStartDate: Date?
    @FocusState private var isQuestionFocused: Bool
    @State private var requestTask: Task<Void, Never>?
    @State private var showsClearConfirmation = false

    // MARK: Run space (quick code execution)

    @State private var runCode = ""
    @State private var runLanguage: CodeRunner.Language = .python
    @State private var runOutput: CodeRunResult?
    @State private var isRunning = false
    @State private var runTask: Task<Void, Never>?

    private let sessionStore = LearningSessionStore.shared
    private let responseBottomID = "learning-response-bottom"
    private let quickPrompts = [
        "这一页主要在讲什么？",
        "用更简单的话解释",
        "给我一个具体例子"
    ]

    var body: some View {
        VStack(spacing: 0) {
            inspectorHeader
            Divider()

            switch mode {
            case .ask:
                askView
            case .notes:
                notesView
            case .run:
                runView
            }
        }
        .background(SatoriTheme.paper)
        .task(id: documentID) { await loadHistory() }
        .onAppear { refreshConfigurationState() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refreshConfigurationState() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .qwenConfigurationDidChange)) { _ in
            refreshConfigurationState()
        }

        // 划选即问 / 划选即运行（PDFReaderView 浮动工具条 → NotificationCenter →
        // 本面板）。URL 匹配当前文档才响应，避免其他书页的划选误触发。
        // 「问 AI」像 Cursor 一样把选中文字放进输入框，不自动发送：
        // 用户可以补充、改写、追问后再自己发送。
        .onReceive(NotificationCenter.default.publisher(for: .satoriAskSelectionRequested)) { note in
            guard let text = note.userInfo?["text"] as? String,
                  let selectionPage = note.userInfo?["pageIndex"] as? Int else { return }
            let sourceURL = note.userInfo?["url"] as? URL
            guard sourceURL == nil || sourceURL == documentURL else { return }
            selectMode(.ask)
            pendingSelectionPage = selectionPage
            if question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                question = text
            } else {
                question += "\n" + text
            }
            // 下一帧聚焦输入框：用户选中后直接接着打字追问，不用再点一下。
            DispatchQueue.main.async {
                isQuestionFocused = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .satoriRunSelectionRequested)) { note in
            guard let text = note.userInfo?["text"] as? String else { return }
            let sourceURL = note.userInfo?["url"] as? URL
            guard sourceURL == nil || sourceURL == documentURL else { return }
            selectMode(.run)
            runCode = text
        }
        .fileImporter(
            isPresented: $isImportingImage,
            allowedContentTypes: [.image],
            allowsMultipleSelection: true,
            onCompletion: importImages
        )
        .alert("清空这本书的学习记录？", isPresented: $showsClearConfirmation) {
            Button("取消", role: .cancel) {}
            Button("清空记录", role: .destructive, action: clearHistory)
        } message: {
            Text("只会删除本机保存的 AI 问答，不会影响 PDF、阅读位置或百炼账户。")
        }
        .onDisappear { requestTask?.cancel() }
        .onChange(of: pageIndex) { _, _ in
            // 用户翻页后，之前选中的上下文不再指向当前阅读位置。
            pendingSelectionPage = nil
            // 章节选择自动同步阅读位置：翻到别的章节时取消手动选择，跟随当前章节。
            if let selectedChapterID,
               let selected = chapters.first(where: { $0.id == selectedChapterID }),
               let current = currentChapter,
               selected.id != current.id {
                self.selectedChapterID = nil
            }
        }
    }

    private var inspectorHeader: some View {
        VStack(spacing: SatoriTheme.Spacing.md) {
            HStack(spacing: SatoriTheme.Spacing.sm) {
                Text("这本书")
                    .font(.headline)
                Spacer()
                Button("回答设置", systemImage: "gearshape") { openSettings() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("打开设置：模型、API Key、回答提示词")
                Button("关闭", systemImage: "xmark", action: onClose)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("关闭学习面板")
            }

            modePicker
        }
        .padding(.horizontal, SatoriTheme.Spacing.lg)
        .padding(.vertical, SatoriTheme.Spacing.md)
        .background(SatoriTheme.paperRaised.opacity(0.6))
        .overlay(alignment: .bottom) { Divider() }
    }

    /// 问 / 笔记 / 运行 — one active space, ⌘1-3.
    private var modePicker: some View {
        HStack(spacing: 2) {
            ForEach(InspectorMode.allCases) { item in
                modeButton(item)
            }
        }
        .padding(3)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func modeButton(_ item: InspectorMode) -> some View {
        let isActive = mode == item
        return Button {
            selectMode(item)
        } label: {
            Label(item.title, systemImage: item.systemImage)
                .font(.caption.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
                .overlay(alignment: .topTrailing) {
                    if item == .notes, turns.count > 0 {
                        Text("\(turns.count)")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(SatoriTheme.accent, in: Capsule())
                            .offset(x: 8, y: -4)
                    }
                }
                .background(
                    isActive ? SatoriTheme.paperRaised : .clear,
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
                .foregroundStyle(isActive ? SatoriTheme.accent : .secondary)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(item.shortcut, modifiers: .command)
        .help("\(item.title)（⌘\(item.shortcut.character)）")
    }

    /// Modes are mutually exclusive; leaving a mode clears its transient
    /// state (stale run output) so the next mode starts clean.
    private func selectMode(_ newMode: InspectorMode) {
        guard newMode != mode else { return }
        if mode == .run {
            stopRunning()
        }
        withAnimation(SatoriTheme.Motion.quick) { mode = newMode }
    }

    /// 正在进行中的这一轮对话：发送提问的瞬间就出现（回答为空、流式填充），
    /// 完成后由 `completeDraft` 归档进 `turns`，界面不跳变。
    private var activeTurn: LearningTurn? {
        guard !draftQuestion.isEmpty else { return nil }
        return LearningTurn(
            question: draftQuestion,
            answer: response?.text ?? "",
            pageIndex: draftPageIndex,
            sourceKind: response?.sourceKind ?? .inference,
            citations: response?.citations ?? [],
            attachmentCount: draftAttachmentCount
        )
    }

    private var isStreamingAnswer: Bool {
        isThinking && !draftQuestion.isEmpty
    }

    /// 问 — 这本书的对话流 + 输入框。所有问答连成一条对话，翻页不消失。
    private var askView: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: SatoriTheme.Spacing.lg) {
                    if let completedPage = completedElsewherePage {
                        savedElsewhereBanner(pageIndex: completedPage)
                    }

                    if isLoadingHistory {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("正在载入这本书的学习记录…")
                        }
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 18)
                    } else if turns.isEmpty, activeTurn == nil {
                        promptStarter
                    } else {
                        // 一条连续的对话流：历史问答 + 正在进行的这一轮。
                        // 提问消息一发送就出现在列表里，回答紧跟其下流式输出。
                        ForEach(turns) { turn in
                            conversationTurnCard(turn)
                                .id(turn.id)
                        }
                        if let activeTurn {
                            conversationTurnCard(activeTurn, isActive: true)
                                .id("streaming-draft")
                        }
                    }

                    if !historyStatus.isEmpty {
                        Label(historyStatus, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Color.clear
                        .frame(height: 1)
                        .id(responseBottomID)
                        .onAppear { isAtBottom = true }
                        .onDisappear { isAtBottom = false }
                }
                .padding(SatoriTheme.Spacing.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollPosition(id: $scrollAnchorID, anchor: .bottom)
            .overlay(alignment: .bottom) {
                if !isAtBottom {
                    Button {
                        scrollAnchorID = responseBottomID
                    } label: {
                        Label("回到底部", systemImage: "arrow.down")
                    }
                    .buttonStyle(.plain)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 11)
                    .padding(.vertical, 5)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(
                        Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.10), radius: 5, y: 1)
                    .padding(.bottom, 7)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .animation(SatoriTheme.Motion.quick, value: isAtBottom)
                }
            }

            Divider()
            composer
        }
    }

    /// 回答完成时用户已经翻页：提示它存进了哪一页，不再"答完就消失"。
    private func savedElsewhereBanner(pageIndex: Int) -> some View {
        HStack(spacing: SatoriTheme.Spacing.sm) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 15))
                .foregroundStyle(SatoriTheme.accent)
            Text("回答已存入第 \(pageIndex + 1) 页笔记")
                .font(.callout.weight(.medium))
            Spacer()
            Button("去看看") {
                onNavigateToPage(pageIndex)
                completedElsewherePage = nil
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .tint(SatoriTheme.accent)
            Button {
                completedElsewherePage = nil
            } label: {
                Image(systemName: "xmark")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("关闭提示")
        }
        .padding(SatoriTheme.Spacing.md)
        .background(
            SatoriTheme.accentWash.opacity(0.7),
            in: RoundedRectangle(cornerRadius: SatoriTheme.Radius.md, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: SatoriTheme.Radius.md, style: .continuous)
                .strokeBorder(SatoriTheme.accent.opacity(0.3), lineWidth: 1)
        )
    }



    private var notesView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: SatoriTheme.Spacing.xl) {
                if isLoadingHistory {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("正在载入这本书的学习记录…")
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 18)
                } else if !historyStatus.isEmpty {
                    VStack(spacing: SatoriTheme.Spacing.sm) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 32))
                            .foregroundStyle(SatoriTheme.gold)
                        Text("学习记录加载失败")
                            .font(.callout.weight(.medium))
                        Text(historyStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, SatoriTheme.Spacing.xxl)
                } else if turns.isEmpty {
                    VStack(spacing: SatoriTheme.Spacing.sm) {
                        Image(systemName: "book.pages")
                            .font(.system(size: 32))
                            .foregroundStyle(.tertiary)
                        Text("还没有笔记")
                            .font(.callout.weight(.medium))
                        Text("去「问」里和 AI 讨论这一页，笔记会自动按页整理在这里。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, SatoriTheme.Spacing.xxl)
                } else {
                    ForEach(pageSections) { section in
                        pageSectionView(section)
                    }
                }
            }
            .padding(SatoriTheme.Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// 运行 — a quick scratchpad to execute code locally. Paste from the PDF
    /// selection (or anywhere), pick a language, hit run, see output.
    private var runView: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: SatoriTheme.Spacing.md) {
                    HStack(spacing: SatoriTheme.Spacing.sm) {
                        Button {
                            selectMode(.ask)
                        } label: {
                            Label("回到对话", systemImage: "chevron.left")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)

                        Picker("语言", selection: $runLanguage) {
                            ForEach(CodeRunner.Language.allCases, id: \.self) { lang in
                                Text(lang.rawValue).tag(lang)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 140)

                        Spacer()

                        if isRunning {
                            HStack(spacing: SatoriTheme.Spacing.xs) {
                                ProgressView().controlSize(.mini)
                                Text("运行中…")
                                    .font(.caption)
                            }
                            .foregroundStyle(.secondary)
                        }

                        Button {
                            if isRunning {
                                stopRunning()
                            } else {
                                runSnippet()
                            }
                        } label: {
                            Label(isRunning ? "停止" : "运行", systemImage: isRunning ? "stop.fill" : "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .tint(SatoriTheme.accent)
                        .disabled(runCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isRunning)
                    }

                    ZStack(alignment: .topLeading) {
                        if runCode.isEmpty {
                            Text("把书里的代码粘贴到这里，或直接在 PDF 里选中一段代码点「运行这段」…")
                                .font(.body)
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, SatoriTheme.Spacing.md + 1)
                                .padding(.vertical, SatoriTheme.Spacing.md)
                                .allowsHitTesting(false)
                        }
                        TextEditor(text: $runCode)
                            .font(.system(.body, design: .monospaced))
                            .scrollContentBackground(.hidden)
                            .padding(SatoriTheme.Spacing.sm)
                            .frame(minHeight: 180, maxHeight: 360)
                            .onKeyPress(.return, phases: .down) { keyPress in
                                guard keyPress.modifiers.contains(.command) else { return .ignored }
                                isRunning ? stopRunning() : runSnippet()
                                return .handled
                            }
                    }
                    .background(SatoriTheme.paperRaised, in: RoundedRectangle(cornerRadius: SatoriTheme.Radius.sm, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: SatoriTheme.Radius.sm, style: .continuous).strokeBorder(SatoriTheme.hairline))

                    if let runOutput {
                        runOutputView(runOutput)
                    }
                }
                .padding(SatoriTheme.Spacing.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func runOutputView(_ result: CodeRunResult) -> some View {
        VStack(alignment: .leading, spacing: SatoriTheme.Spacing.sm) {
            HStack(spacing: SatoriTheme.Spacing.sm) {
                Image(systemName: result.exitCode == 0 ? "checkmark.circle" : "xmark.octagon")
                    .foregroundStyle(result.exitCode == 0 ? Color.green : Color.red)
                Text(result.timedOut ? "运行超时，已停止" : (result.exitCode == 0 ? "运行完成" : "运行出错"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if result.exitCode != 0 && !result.timedOut {
                    Text("退出码 \(result.exitCode)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Button("复制输出", systemImage: "doc.on.doc") {
                    copyToPasteboard(result.stdout)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .help("复制输出")
            }

            let body = (result.stdout.isEmpty ? "" : result.stdout) + (result.stderr.isEmpty ? "" : (result.stdout.isEmpty ? result.stderr : "\n" + result.stderr))
            Text(body.isEmpty ? "（无输出）" : body)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(result.stderr.isEmpty ? Color.primary : Color.red)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(SatoriTheme.Spacing.md)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: SatoriTheme.Radius.sm, style: .continuous))
        }
    }

    private func runSnippet() {
        let code = runCode
        guard !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !isRunning else { return }
        isRunning = true
        runOutput = nil
        let language = runLanguage
        runTask = Task {
            let result = await CodeRunner.run(code: code, language: language)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                runOutput = result
                isRunning = false
            }
            // Running code counts as studying — feeds the 动手达人 badge.
            try? await LearningStatsStore.shared.recordCodeRun(documentID: documentID)
            NotificationCenter.default.post(name: .learningStatsDidChange, object: nil)
        }
    }

    private func stopRunning() {
        // 取消运行任务会真正终止进程（CodeRunner 在取消时 SIGTERM→SIGKILL），
        // 不再只是把按钮翻回去、让程序在后台跑到超时。
        runTask?.cancel()
        runTask = nil
        isRunning = false
    }

    /// Turns grouped by the page they belong to, so the panel reads as
    /// per-page margin notes on the book rather than a disconnected chat log.
    private struct PageSection: Identifiable {
        let pageIndex: Int
        let turns: [LearningTurn]
        var id: Int { pageIndex }
    }

    private var pageSections: [PageSection] {
        let grouped = Dictionary(grouping: turns, by: \.pageIndex)
        // 最近有问答的页排前面：像成长记录，而不是按页码归档的档案。
        return grouped.keys.sorted { lhs, rhs in
            let lastA = grouped[lhs]?.last?.createdAt ?? .distantPast
            let lastB = grouped[rhs]?.last?.createdAt ?? .distantPast
            return lastA > lastB
        }.map { PageSection(pageIndex: $0, turns: grouped[$0] ?? []) }
    }

    private var promptStarter: some View {
        VStack(alignment: .leading, spacing: SatoriTheme.Spacing.md) {
            VStack(alignment: .leading, spacing: SatoriTheme.Spacing.xs + 1) {
                Text("从不懂的地方开始")
                    .font(.title3.weight(.semibold))
                Text("不用整理笔记。先问清一个概念，再沿着答案继续追问。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: SatoriTheme.Spacing.sm) {
                ForEach(quickPrompts, id: \.self) { prompt in
                    // 快捷提问就是围绕当前页的，显式带上页上下文；
                    // 输入框里手打的问题默认不带上下文，用户可按需选择。
                    QuickPromptButton(prompt: prompt) { askAssistant(prompt, scope: .page) }
                }
            }

            if !hasQwenConfiguration {
                Button("连接 Qwen", systemImage: "key") { openSettings() }
                    .buttonStyle(.bordered)
                    .tint(SatoriTheme.accent)
            }
        }
        .padding(.vertical, SatoriTheme.Spacing.xs)
    }

    /// 一轮对话：右侧你的问题气泡 + 左侧 AI 回答卡片。历史与进行中的
    /// 这一轮共用同一组件，发送/归档时界面不跳变。
    private func conversationTurnCard(_ turn: LearningTurn, isActive: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: SatoriTheme.Spacing.sm) {
            userMessageBubble(
                question: turn.question,
                pageIndex: turn.pageIndex,
                contextScope: turn.contextScope,
                attachmentCount: turn.attachmentCount,
                createdAt: turn.createdAt,
                previews: isActive ? activeAttachmentPreviews : []
            )
            answerCard(turn: turn, isActive: isActive)
        }
    }

    /// 你的消息：右对齐气泡，页码可点回原文。
    private func userMessageBubble(
        question: String,
        pageIndex: Int,
        contextScope: LearningContextScope?,
        attachmentCount: Int,
        createdAt: Date,
        previews: [NSImage]
    ) -> some View {
        HStack {
            Spacer(minLength: 48)
            VStack(alignment: .trailing, spacing: 5) {
                Text(question)
                    .font(.body)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if !previews.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(Array(previews.enumerated()), id: \.offset) { _, image in
                            Image(nsImage: image)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 56, height: 44)
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .strokeBorder(.white.opacity(0.35), lineWidth: 1)
                                )
                        }
                    }
                    .padding(.top, 2)
                }
                HStack(spacing: 10) {
                    if attachmentCount > 0 {
                        Text("\(attachmentCount) 张附图")
                    }
                    if let label = contextAnchorLabel(contextScope, pageIndex: pageIndex) {
                        if contextScope == .some(.wholeDocument) {
                            Text(label)
                        } else {
                            Button(label) { onNavigateToPage(pageIndex) }
                                .buttonStyle(.plain)
                        }
                    }
                    Text(createdAt, style: .time)
                }
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.85))
            }
            .padding(.horizontal, SatoriTheme.Spacing.md)
            .padding(.vertical, 10)
            .background(
                SatoriTheme.accentButton,
                in: RoundedRectangle(cornerRadius: SatoriTheme.Radius.md, style: .continuous)
            )
            .foregroundStyle(.white)
        }
    }

    /// 气泡里展示「这一轮问答依据什么」；nil 视为旧版本数据（按「当前页」理解）。
    private func contextAnchorLabel(_ scope: LearningContextScope?, pageIndex: Int) -> String? {
        switch scope {
        case .some(.none):
            // 不带上下文：不显示页码锚点，避免误导。
            return nil
        case .some(.page), nil:
            return "第 \(pageIndex + 1) 页"
        case let .some(.pageRange(start, end)):
            return start == end ? "第 \(start + 1) 页" : "第 \(start + 1)–\(end + 1) 页"
        case .some(.wholeDocument):
            return "整本书"
        }
    }

    /// 「过程」脚注里的一枚小标签：这一轮问答实际发生了什么。
    private struct ProcessChip: Equatable {
        let symbol: String
        let text: String
    }

    /// 回答卡片底部的处理过程：上下文、附图、联网搜索来源、模型、耗时。
    private func processChips(turn: LearningTurn, isActive: Bool) -> [ProcessChip] {
        var chips: [ProcessChip] = []
        if let label = contextAnchorLabel(turn.contextScope, pageIndex: turn.pageIndex) {
            chips.append(.init(symbol: "book", text: label))
        }
        if turn.attachmentCount > 0 {
            chips.append(.init(symbol: "paperclip", text: "附图 \(turn.attachmentCount) 张"))
        }
        if isActive, allowsWebSearch {
            chips.append(.init(symbol: "globe", text: "正在联网搜索…"))
        } else if !turn.citations.isEmpty {
            chips.append(.init(symbol: "globe", text: "联网搜索 · \(turn.citations.count) 个来源"))
        }
        if let modelID = configuredModelID, !modelID.isEmpty {
            chips.append(.init(symbol: "cpu", text: modelID))
        }
        if !isActive, let duration = turn.responseDuration {
            chips.append(.init(symbol: "clock", text: String(format: "%.1fs", duration)))
        }
        return chips
    }

    private func processFooter(turn: LearningTurn, isActive: Bool) -> some View {
        HStack(spacing: 6) {
            ForEach(Array(processChips(turn: turn, isActive: isActive).enumerated()), id: \.offset) { _, chip in
                Label(chip.text, systemImage: chip.symbol)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.05), in: Capsule())
            }
            if isActive, isStreamingAnswer {
                // 流式期间实时显示已用时间，不再靠猜。
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Label(elapsedString(context.date), systemImage: "clock")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.05), in: Capsule())
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 2)
    }

    private func elapsedString(_ now: Date) -> String {
        guard let start = streamStartDate else { return "…" }
        let seconds = now.timeIntervalSince(start)
        if seconds < 60 { return String(format: "%.0fs", seconds) }
        return String(format: "%.0f:%02.0f", seconds / 60, seconds.truncatingRemainder(dividingBy: 60))
    }

    /// AI 回答：左对齐卡片。进行中时金色描边 + 流式输出。
    private func answerCard(turn: LearningTurn, isActive: Bool) -> some View {
        let isStreaming = isActive && isStreamingAnswer
        return VStack(alignment: .leading, spacing: 12) {
            // 回答直接平铺在纸面上：不再用白色卡片气泡，也没有黄色强调描边。
            Divider()
            answerHeader(
                sourceKind: turn.sourceKind,
                isStreaming: isStreaming,
                completion: turn.completion
            )
            if isStreaming, turn.answer.isEmpty {
                HStack(spacing: SatoriTheme.Spacing.sm) {
                    ProgressView().controlSize(.small)
                    Text(streamingStatusText)
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
                .padding(.vertical, SatoriTheme.Spacing.xs + 2)
            } else {
                LearningMarkdownView(markdown: turn.answer)
                if isActive ? (response?.isTruncated ?? false) : looksTruncated(turn.answer) {
                    truncatedAnswerNotice
                }
                if isStreaming, turn.citations.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "link")
                        Text("正在整理来源…")
                    }
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                }
                citationsView(turn.citations)
            }
            processFooter(turn: turn, isActive: isActive)
            if isActive, !isStreaming, turn.sourceKind == .inference {
                HStack {
                    if !hasQwenConfiguration {
                        Button("连接 Qwen", systemImage: "key") { openSettings() }
                            .buttonStyle(.borderless)
                    }
                    Spacer()
                    Button("重试", systemImage: "arrow.clockwise") {
                        askAssistant(
                            turn.question,
                            pageOverride: turn.pageIndex,
                            scope: turn.contextScope ?? .page
                        )
                    }
                    .buttonStyle(.borderless)
                }
            }
            if !isActive {
                turnActions(turn)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, SatoriTheme.Spacing.xs)
    }

    /// A page in the margin notes: "第 N 页" header followed by that page's turns.
    private func pageSectionView(_ section: PageSection) -> some View {
        VStack(alignment: .leading, spacing: SatoriTheme.Spacing.sm) {
            Button {
                onNavigateToPage(section.pageIndex)
            } label: {
                HStack(spacing: SatoriTheme.Spacing.sm) {
                    Text("第 \(section.pageIndex + 1) 页")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    if section.pageIndex == pageIndex {
                        Text("当前页")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(SatoriTheme.accentWash, in: Capsule())
                    }
                    Spacer()
                    Text("\(section.turns.count) 条")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
            .help("跳到第 \(section.pageIndex + 1) 页")

            ForEach(section.turns) { turn in
                conversationTurnCard(turn)
                    .id(turn.id)
            }
        }
    }

    private func answerHeader(
        sourceKind: LearningSourceKind,
        isStreaming: Bool,
        completion: LearningTurnCompletion
    ) -> some View {
        HStack {
            Label(
                isStreaming ? "Qwen 正在回答" : sourceKind.localizedTitle,
                systemImage: isStreaming ? "sparkles" : "checkmark.seal"
            )
            .font(.caption.weight(.semibold))
            .foregroundStyle(SatoriTheme.accent)
            if completion == .stopped {
                Text("已停止")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.1), in: Capsule())
            }
            Spacer()
        }
    }

    @ViewBuilder
    private func citationsView(_ citations: [LearningCitation]) -> some View {
        if !citations.isEmpty {
            Divider()
            VStack(alignment: .leading, spacing: 7) {
                Text("网页来源")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(citations) { citation in
                    Link(destination: citation.url) {
                        Label(citation.title, systemImage: "arrow.up.right.square")
                            .font(.caption)
                            .lineLimit(2)
                    }
                }
            }
        }
    }

    private var truncatedAnswerNotice: some View {
        Label("回答因长度限制不完整", systemImage: "text.line.last.and.arrowtriangle.forward")
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, SatoriTheme.Spacing.sm)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: SatoriTheme.Radius.sm, style: .continuous))
    }

    /// 流式回答会标记真实的 `response.isTruncated`（SSE response.incomplete）；
    /// 历史 turn 未存该字段，用"足够长且结尾缺少终止标点"近似兜底，避免被截断
    /// 的长回答毫无提示。
    private func looksTruncated(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 400 else { return false }
        if trimmed.hasSuffix("```") { return false }
        guard let last = trimmed.last else { return false }
        return !"。！？!?…~”」』）)]}*_`".contains(last)
    }

    private func turnActions(_ turn: LearningTurn) -> some View {
        HStack(spacing: 12) {
            Spacer()
            Button("复制", systemImage: "doc.on.doc") { copyToPasteboard(turn.answer) }
                .buttonStyle(.borderless)
            Button("重试", systemImage: "arrow.clockwise") {
                onNavigateToPage(turn.pageIndex)
                askAssistant(
                    turn.question,
                    pageOverride: turn.pageIndex,
                    excludingTurnID: turn.id,
                    scope: turn.contextScope ?? .page
                )
            }
            .buttonStyle(.borderless)
            Menu {
                Button("删除这一轮", systemImage: "trash", role: .destructive) {
                    deleteTurn(turn.id)
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 24)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: SatoriTheme.Spacing.sm) {
            if !attachments.isEmpty { attachmentStrip }

            contextScopeRow

            ZStack(alignment: .topLeading) {
                if question.isEmpty {
                    Text(turns.isEmpty ? "想问什么？可以附上图片…" : "继续追问这里为什么、再举个例子…")
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, SatoriTheme.Spacing.md + 1)
                        .padding(.vertical, SatoriTheme.Spacing.md)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $question)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(SatoriTheme.Spacing.sm)
                    .frame(minHeight: 68, maxHeight: 104)
                    .focused($isQuestionFocused)
                    .onKeyPress(.return, phases: .down) { keyPress in
                        if keyPress.modifiers.contains(.shift) { return .ignored }
                        if canSend { askAssistant() }
                        return .handled
                    }
                    .onKeyPress(keys: ["v"], phases: .down) { keyPress in
                        guard keyPress.modifiers.contains(.command) else { return .ignored }
                        return pasteFromPasteboard() ? .handled : .ignored
                    }
            }
            .background(SatoriTheme.paperRaised, in: RoundedRectangle(cornerRadius: SatoriTheme.Radius.sm, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: SatoriTheme.Radius.sm, style: .continuous)
                    .strokeBorder(SatoriTheme.accent.opacity(isQuestionFocused ? 0.6 : 0.24), lineWidth: isQuestionFocused ? 1.5 : 1)
            )
            .animation(SatoriTheme.Motion.quick, value: isQuestionFocused)

            if !attachmentStatus.isEmpty {
                Text(attachmentStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("添加图片", systemImage: "photo.badge.plus") { isImportingImage = true }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("添加图片（最多 4 张）")
                    .disabled(attachments.count >= 4 || isThinking)

                Button("粘贴图片", systemImage: "doc.on.clipboard") { _ = pasteFromPasteboard() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("粘贴剪贴板里的图片（⌘V）")
                    .disabled(attachments.count >= 4 || isThinking)

                Toggle(isOn: $allowsWebSearch) {
                    Label("联网", systemImage: "globe")
                }
                .toggleStyle(.button)
                .controlSize(.small)
                .help("允许这次提问使用 Qwen 网页搜索")

                Button {
                    selectMode(.run)
                } label: {
                    Label("运行代码", systemImage: "play.rectangle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(SatoriTheme.accent)
                .help("打开代码运行台")

                Spacer()
                Button {
                    isThinking ? stopAssistant() : askAssistant()
                } label: {
                    Label(isThinking ? "停止" : "发送", systemImage: isThinking ? "stop.fill" : "arrow.up")
                }
                .buttonStyle(.borderedProminent)
                .tint(SatoriTheme.accent)
                .disabled(!isThinking && !canSend)
            }
            Text(composerHint)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(SatoriTheme.Spacing.md)
        .background(.bar)
    }

    /// 提问参考上下文选择：默认不带页上下文，需要时再选当前页/多页/整本书。
    private var contextScopeRow: some View {
        HStack(spacing: SatoriTheme.Spacing.sm) {
            Menu {
                Picker("参考上下文", selection: contextModeBinding) {
                    Label("不带上下文", systemImage: "text.bubble").tag(ContextMode.none)
                    Label("当前页", systemImage: "doc.text").tag(ContextMode.page)
                    if !chapters.isEmpty {
                        Label("章节", systemImage: "list.bullet.rectangle").tag(ContextMode.chapter)
                    }
                    Label("多页…", systemImage: "doc.on.doc").tag(ContextMode.pageRange)
                    Label("整本书", systemImage: "books.vertical").tag(ContextMode.wholeDocument)
                }
                .pickerStyle(.inline)
            } label: {
                Label(contextModePickerTitle, systemImage: contextModeSystemImage)
            }
            .menuStyle(.borderlessButton)
            .font(.caption)
            .foregroundStyle(.secondary)
            .help("提问时给 AI 的参考内容。默认不带上下文，需要时再选。")

            if contextMode == .chapter, !chapters.isEmpty {
                chapterPickerMenu
            }

            if contextMode == .pageRange {
                Stepper("起始页", value: $rangeStart, in: 1...max(1, rangeEnd - 1))
                    .labelsHidden()
                    .controlSize(.small)
                Stepper("结束页", value: $rangeEnd, in: rangeStart...max(rangeStart, pageCount))
                    .labelsHidden()
                    .controlSize(.small)
            }

            Spacer()
        }
    }

    /// 「章节」上下文里的章节选择器：默认当前章节，可任选一章。
    /// 按章分组、章下用子菜单展开节/小节，条目再多也不会变成一长条平铺列表。
    private var chapterPickerMenu: some View {
        Menu {
            ForEach(groupedChapters, id: \.chapter.id) { group in
                if group.sections.isEmpty {
                    Button {
                        selectedChapterID = group.chapter.id
                    } label: {
                        chapterRowLabel(group.chapter)
                    }
                } else {
                    Menu {
                        // 子菜单第一项是整章，下面再展开这一章的节/小节。
                        Button {
                            selectedChapterID = group.chapter.id
                        } label: {
                            chapterRowLabel(group.chapter)
                        }
                        Divider()
                        ForEach(group.sections) { section in
                            Button {
                                selectedChapterID = section.id
                            } label: {
                                chapterRowLabel(section)
                            }
                        }
                    } label: {
                        chapterRowLabel(group.chapter)
                    }
                }
            }
        } label: {
            Label(activeChapter?.title ?? "选择章节", systemImage: "list.bullet.rectangle")
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .font(.caption)
        .foregroundStyle(.secondary)
        .help("选择要提问的章节；翻页后会自动跟随当前章节")
    }

    /// 章（depth ≤ 1）作为一级菜单，其下到下一章之前的所有条目归入该章的子菜单。
    private var groupedChapters: [(chapter: BookChapter, sections: [BookChapter])] {
        var result: [(chapter: BookChapter, sections: [BookChapter])] = []
        var current: BookChapter?
        var sections: [BookChapter] = []
        for chapter in chapters {
            if chapter.depth <= 1 {
                if let current {
                    result.append((current, sections))
                }
                current = chapter
                sections = []
            } else {
                sections.append(chapter)
            }
        }
        if let current {
            result.append((current, sections))
        }
        return result
    }

    private func chapterRowLabel(_ chapter: BookChapter) -> some View {
        HStack(spacing: 6) {
            if chapter.id == activeChapter?.id {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.semibold))
                    .frame(width: 12)
            } else {
                Color.clear.frame(width: 12, height: 1)
            }
            Text(chapter.title)
                .font(.caption)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(chapterPageRangeLabel(chapter))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .padding(.leading, CGFloat(min(max(chapter.depth - 1, 0), 3)) * 10)
    }

    private func chapterPageRangeLabel(_ chapter: BookChapter) -> String {
        if let range = BookChapter.pageRange(for: chapter, in: chapters, pageCount: pageCount) {
            return "\(range.lowerBound + 1)–\(range.upperBound + 1)"
        }
        return "\(chapter.pageIndex + 1)"
    }

    /// 当前页所属的章节（最后一个起始页 ≤ 当前页）。
    private var currentChapter: BookChapter? {
        chapters.last { $0.pageIndex <= pageIndex }
    }

    /// 实际使用的章节：用户选中的优先，否则跟随当前章节。
    private var activeChapter: BookChapter? {
        if let selectedChapterID, let chapter = chapters.first(where: { $0.id == selectedChapterID }) {
            return chapter
        }
        return currentChapter
    }

    /// 切到「多页」时默认从当前页开始，再往前后扩展。
    private var contextModeBinding: Binding<ContextMode> {
        Binding(
            get: { contextMode },
            set: { newMode in
                if newMode == .chapter {
                    selectedChapterID = nil // 重新选择时默认跟随当前章节
                }
                if newMode == .pageRange {
                    let anchor = min(max(pageIndex + 1, 1), pageCount)
                    rangeStart = anchor
                    rangeEnd = anchor
                }
                contextMode = newMode
            }
        )
    }

    private var contextModePickerTitle: String {
        switch contextMode {
        case .none: "不带上下文"
        case .page: "当前页"
        case .chapter:
            if let activeChapter,
               let range = BookChapter.pageRange(for: activeChapter, in: chapters, pageCount: pageCount) {
                "章节 · \(activeChapter.title)（第 \(range.lowerBound + 1)–\(range.upperBound + 1) 页）"
            } else {
                "章节"
            }
        case .pageRange:
            rangeStart == rangeEnd ? "第 \(rangeStart) 页" : "第 \(rangeStart)–\(rangeEnd) 页"
        case .wholeDocument: "整本书"
        }
    }

    private var contextModeSystemImage: String {
        switch contextMode {
        case .none: "text.bubble"
        case .page: "doc.text"
        case .chapter: "list.bullet.rectangle"
        case .pageRange: "doc.on.doc"
        case .wholeDocument: "books.vertical"
        }
    }

    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 9) {
                ForEach(attachments) { attachment in
                    ZStack(alignment: .topTrailing) {
                        Image(nsImage: attachment.preview)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 64, height: 52)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
                            .help(attachment.name)
                        Button {
                            attachments.removeAll { $0.id == attachment.id }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, .black.opacity(0.7))
                        }
                        .buttonStyle(.plain)
                        .offset(x: 5, y: -5)
                        .help("移除 \(attachment.name)")
                    }
                    .padding(.top, 5)
                    .padding(.trailing, 5)
                }
            }
        }
        .frame(height: 62)
    }

    private var canSend: Bool {
        !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isThinking
    }

    private var composerHint: String {
        let web = allowsWebSearch ? "、联网" : ""
        let scopeText: String
        switch contextMode {
        case .none: scopeText = "不带上下文"
        case .page: scopeText = "第 \(pageIndex + 1) 页"
        case .chapter:
            scopeText = activeChapter?.title ?? "章节"
        case .pageRange: scopeText = "第 \(rangeStart)–\(rangeEnd) 页"
        case .wholeDocument: scopeText = "整本书"
        }
        return "Enter 发送 · Shift+Enter 换行 · ⌘V 贴图 · 参考：\(scopeText)、最近对话、附件\(web)"
    }

    private var streamingStatusText: String {
        if allowsWebSearch { return "正在联网搜索资料并组织回答…" }
        if contextMode == .chapter {
            if case .pageRange = draftContextScope {
                return "正在通读章节内容找依据…"
            }
        }
        return switch draftContextScope {
        case .none: "正在思考…"
        case .page: "正在理解当前页…"
        case .pageRange: "正在结合所选多页理解…"
        case .wholeDocument: "正在通读全书找依据…"
        }
    }

    @MainActor
    private func loadHistory() async {
        isLoadingHistory = true
        historyStatus = ""
        do {
            turns = try await sessionStore.turns(for: documentID)
            // 打开面板默认看最新对话：锚定到底部，历史加载完自动贴底。
            scrollAnchorID = responseBottomID
        } catch {
            turns = []
            historyStatus = "学习记录暂时无法读取；不影响继续阅读和提问。"
        }
        isLoadingHistory = false
    }

    private func askAssistant(
        _ suppliedQuestion: String? = nil,
        pageOverride: Int? = nil,
        excludingTurnID: UUID? = nil,
        scope: LearningContextScope = .page
    ) {
        let request = (suppliedQuestion ?? question).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty, !isThinking else { return }

        // 输入框发送（suppliedQuestion == nil）优先沿用「问 AI」选中的页码；
        // 快捷提问、时间线重问各自带自己的上下文。
        let targetPageIndex: Int
        if let pageOverride {
            targetPageIndex = pageOverride
        } else if suppliedQuestion == nil {
            targetPageIndex = pendingSelectionPage ?? pageIndex
            pendingSelectionPage = nil
        } else {
            targetPageIndex = pageIndex
        }

        // 输入框发送跟着选择器走（默认不带上下文）；快捷提问、重问各自带上下文。
        let effectiveScope: LearningContextScope
        if suppliedQuestion == nil {
            switch contextMode {
            case .none:
                effectiveScope = .none
            case .page:
                effectiveScope = .page
            case .chapter:
                if let activeChapter,
                   let range = BookChapter.pageRange(for: activeChapter, in: chapters, pageCount: pageCount) {
                    effectiveScope = .pageRange(start: range.lowerBound, end: range.upperBound)
                } else {
                    effectiveScope = .page
                }
            case .pageRange:
                let start = max(1, min(rangeStart, pageCount))
                let end = max(start, min(rangeEnd, pageCount))
                effectiveScope = .pageRange(start: start - 1, end: end - 1)
            case .wholeDocument:
                effectiveScope = .wholeDocument
            }
        } else {
            effectiveScope = scope
        }

        let submittedAttachments = attachments
        activeAttachmentPreviews = submittedAttachments.map(\.preview)
        let context = turns
            .filter { $0.id != excludingTurnID }
            .suffix(6)
            .map {
                LearningConversationContext(
                    question: $0.question,
                    answer: $0.answer,
                    pageIndex: $0.contextScope == .none ? nil : $0.pageIndex,
                    attachmentSummary: $0.attachmentCount > 0 ? "\($0.attachmentCount) 张附图" : nil
                )
            }

        draftQuestion = request
        draftPageIndex = targetPageIndex
        draftContextScope = effectiveScope
        draftAttachmentCount = submittedAttachments.count
        // 锚定到底部：新消息出现后内容自然向上生长，平滑贴底跟随。
        scrollAnchorID = responseBottomID
        question = ""
        attachments = []
        attachmentStatus = ""
        response = LearningResponse(text: "", sourceKind: .currentPDF, pageIndex: targetPageIndex)
        isThinking = true
        streamStartDate = .now
        completedElsewherePage = nil

        requestTask = Task {
            // 配置读取很快（钥匙串结果有进程内缓存），放在前面，
            // 扫描页 OCR 需要配置；没配置就直接提示，不必白跑提取。
            let configuration = await Task.detached(priority: .userInitiated) {
                (config: QwenConfigurationStore.read(), prompt: QwenConfigurationStore.readCustomPrompt())
            }.value
            if Task.isCancelled { return }
            guard let config = configuration.config else {
                hasQwenConfiguration = false
                restoreSubmittedAttachments(submittedAttachments)
                isThinking = false
                streamStartDate = nil
                requestTask = nil
                response = LearningResponse(
                    text: "请先在设置中连接 Qwen。百炼 API Key 只会保存在这台 Mac 的钥匙串中。",
                    sourceKind: .inference,
                    pageIndex: targetPageIndex
                )
                return
            }
            hasQwenConfiguration = true

            // 不带上下文时直接跳过 PDF 提取，提问零等待、请求也不夹带页面。
            // 需要上下文时，提取（含扫描页渲染 + Qwen OCR）放到后台任务，
            // 完成后回主线程，提问瞬间不再冻结 UI。
            let pageContent: LearningPageContent?
            if case .none = effectiveScope {
                pageContent = nil
            } else {
                let extractionScope: PDFPageContextExtractor.Scope = {
                    switch effectiveScope {
                    case .none: .none
                    case .page: .page(targetPageIndex)
                    case let .pageRange(start, end): .pageRange(start...end)
                    case .wholeDocument: .wholeDocument
                    }
                }()
                pageContent = await Task.detached(priority: .userInitiated) {
                    await PDFPageContextExtractor.extract(
                        from: documentURL,
                        scope: extractionScope,
                        qwenConfiguration: config
                    )
                }.value
            }
            if Task.isCancelled { return }
            guard let pageContent else {
                restoreSubmittedAttachments(submittedAttachments)
                isThinking = false
                streamStartDate = nil
                requestTask = nil
                response = LearningResponse(
                    text: scopeExtractionFailureMessage(effectiveScope, pageIndex: targetPageIndex),
                    sourceKind: .inference,
                    pageIndex: targetPageIndex
                )
                return
            }
            let assistant = QwenLearningAssistant(
                apiKey: config.apiKey,
                modelID: config.modelID,
                pageContent: pageContent,
                additionalImagesJPEG: submittedAttachments.map(\.jpegData),
                conversationContext: context,
                allowsWebSearch: allowsWebSearch,
                instructions: configuration.prompt
            )
            var latestResponse: LearningResponse?
            for await update in assistant.streamExplain(request: request, pageIndex: targetPageIndex) {
                if Task.isCancelled { return }
                latestResponse = update
                response = update
            }
            let responseDuration = streamStartDate.map { Date().timeIntervalSince($0) }
            if Task.isCancelled { return }
            isThinking = false
            streamStartDate = nil
            requestTask = nil
            guard let latestResponse else {
                restoreSubmittedAttachments(submittedAttachments)
                // 流里一条消息都没有（连接异常、空响应）：给明确提示，而不是
                // 留下一张空白卡片让用户以为应用卡死、只能重启。
                response = LearningResponse(
                    text: "没有收到回答，请重试。",
                    sourceKind: .inference,
                    pageIndex: targetPageIndex
                )
                return
            }
            if latestResponse.sourceKind == .inference {
                restoreSubmittedAttachments(submittedAttachments)
                response = latestResponse
            } else {
                completeDraft(with: latestResponse, completion: .completed, duration: responseDuration)
            }
        }
    }

    /// 发送失败（未配置 / 页提取失败 / 回答报错）时把贴的图还回输入框，
    /// 避免图片悄悄丢失、重试时找不到图。
    private func restoreSubmittedAttachments(_ submitted: [LearningImageAttachment]) {
        guard !submitted.isEmpty else {
            activeAttachmentPreviews = []
            return
        }
        attachments = submitted
        activeAttachmentPreviews = []
        attachmentStatus = "图片已保留在输入框，修改问题后可以直接重新发送。"
    }

    private func scopeExtractionFailureMessage(_ scope: LearningContextScope, pageIndex: Int) -> String {
        switch scope {
        case .none: ""
        case .page: "暂时无法读取第 \(pageIndex + 1) 页。请确认 PDF 文件仍然可以打开。"
        case .pageRange: "所选页里没有读到可用的文字（可能是纯图片页）。可以改选“当前页”，Satori 会把该页作为图片交给 AI。"
        case .wholeDocument: "这本书里没有可提取的文字（可能是扫描版）。可以改用“当前页”，Satori 会把该页作为图片交给 AI。"
        }
    }

    private func stopAssistant() {
        requestTask?.cancel()
        requestTask = nil
        isThinking = false
        let duration = streamStartDate.map { Date().timeIntervalSince($0) }
        streamStartDate = nil
        guard let response, !response.text.isEmpty, response.sourceKind != .inference else {
            // 还没有真实回答（没产出文字或只有推断态）：直接清掉草稿，
            // 不给时间线留一个「已停止」空壳卡。
            draftQuestion = ""
            draftAttachmentCount = 0
            draftContextScope = .none
            activeAttachmentPreviews = []
            self.response = nil
            return
        }
        completeDraft(with: response, completion: .stopped, duration: duration)
    }

    private func completeDraft(
        with finalResponse: LearningResponse,
        completion: LearningTurnCompletion,
        duration: TimeInterval? = nil
    ) {
        let targetPage = draftPageIndex
        let turn = LearningTurn(
            question: draftQuestion,
            answer: finalResponse.text,
            pageIndex: targetPage,
            sourceKind: finalResponse.sourceKind,
            citations: finalResponse.citations,
            attachmentCount: draftAttachmentCount,
            completion: completion,
            contextScope: draftContextScope,
            responseDuration: duration
        )
        turns.append(turn)
        draftQuestion = ""
        draftAttachmentCount = 0
        draftContextScope = .none
        activeAttachmentPreviews = []
        response = nil
        persistTurns()
        // A completed Q&A counts as studying — feeds the 勤学好问 badge.
        Task {
            try? await LearningStatsStore.shared.recordQuestion(documentID: documentID)
            NotificationCenter.default.post(name: .learningStatsDidChange, object: nil)
        }
        // 回答完成时用户可能已经翻到别的页：提示它存进了哪一页，不再"消失"。
        if targetPage != pageIndex {
            completedElsewherePage = targetPage
        }
    }

    private func deleteTurn(_ turnID: UUID) {
        turns.removeAll { $0.id == turnID }
        persistTurns()
    }

    private func clearHistory() {
        requestTask?.cancel()
        requestTask = nil
        isThinking = false
        streamStartDate = nil
        turns = []
        draftQuestion = ""
        response = nil
        activeAttachmentPreviews = []
        attachments = []
        attachmentStatus = ""
        completedElsewherePage = nil
        pendingSelectionPage = nil
        Task {
            do {
                try await sessionStore.clear(for: documentID)
            } catch {
                historyStatus = "学习记录未能完全清空，请稍后再试。"
            }
        }
    }

    private func persistTurns() {
        let snapshot = turns
        Task {
            do {
                try await sessionStore.save(snapshot, for: documentID)
                historyStatus = ""
            } catch {
                historyStatus = "这次回答暂时未能保存到本机。"
            }
        }
    }

    /// Handles Cmd+V. Pulls any images off the pasteboard into attachments and
    /// returns whether it consumed the event; when there is no image we let the
    /// text editor paste text as usual.
    private func pasteFromPasteboard() -> Bool {
        // 主线程只快速取剪贴板对象；压缩/缩放放到后台并行做，贴大图不卡界面。
        let images = NSPasteboard.general.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage] ?? []
        let valid = images.enumerated().filter { $0.element.size.width > 0 && $0.element.size.height > 0 }
        guard !valid.isEmpty else { return false }

        let remaining = max(0, 4 - attachments.count)
        guard remaining > 0 else {
            attachmentStatus = "每次最多附加 4 张图片，粘贴的图片没有加入。"
            return true
        }
        let selected = Array(valid.prefix(remaining))
        let extraCount = valid.count - selected.count
        let items = selected.map { (name: "粘贴图片 \($0.offset + 1)", image: $0.element) }
        Task {
            let loaded = await LearningImageAttachmentLoader.normalizeConcurrently(items)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                attachments.append(contentsOf: loaded)
                attachmentStatus = extraCount > 0 ? "每次最多附加 4 张图片，其余图片没有加入。" : ""
            }
        }
        return true
    }

    private func importImages(_ result: Result<[URL], Error>) {
        do {
            let urls = try result.get()
            let remaining = max(0, 4 - attachments.count)
            let selected = Array(urls.prefix(remaining))
            let extraCount = urls.count - selected.count
            guard !selected.isEmpty else {
                attachmentStatus = extraCount > 0 ? "每次最多附加 4 张图片，其余图片没有加入。" : ""
                return
            }
            // 读取与压缩在后台并行，多张大图也不会卡住输入框。
            Task {
                let loaded = await Task.detached(priority: .userInitiated) {
                    await LearningImageAttachmentLoader.loadConcurrently(from: selected)
                }.value
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    if loaded.isEmpty {
                        attachmentStatus = "这些图片无法读取，请换一张常见格式的图片。"
                    } else {
                        attachments.append(contentsOf: loaded)
                        attachmentStatus = extraCount > 0 ? "每次最多附加 4 张图片，其余图片没有加入。" : ""
                    }
                }
            }
        } catch CocoaError.userCancelled {
            attachmentStatus = ""
        } catch {
            attachmentStatus = error.localizedDescription
        }
    }

    private func refreshConfigurationState() {
        let markedAsConfigured = QwenConfigurationStore.hasSavedConfigurationMarker()
        hasQwenConfiguration = markedAsConfigured
        configuredModelID = QwenConfigurationStore.readModelID()
        guard markedAsConfigured, !isCheckingConfiguration else { return }
        isCheckingConfiguration = true
        Task {
            let hasConfiguration = await Task.detached(priority: .utility) {
                QwenConfigurationStore.read() != nil
            }.value
            guard !Task.isCancelled else { return }
            hasQwenConfiguration = hasConfiguration
            isCheckingConfiguration = false
        }
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// A starter-prompt row with hover and press feedback, so the empty state
/// feels tactile instead of like static list items.
private struct QuickPromptButton: View {
    let prompt: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack {
                Text(prompt)
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isHovering ? SatoriTheme.accent : Color.secondary.opacity(0.6))
            }
            .contentShape(Rectangle())
            .padding(SatoriTheme.Spacing.md)
            .background(
                isHovering ? SatoriTheme.accentWash : Color(nsColor: .controlBackgroundColor).opacity(0.6),
                in: RoundedRectangle(cornerRadius: SatoriTheme.Radius.sm, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: SatoriTheme.Radius.sm, style: .continuous)
                    .strokeBorder(isHovering ? SatoriTheme.accent.opacity(0.35) : Color.primary.opacity(0.07), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(SatoriTheme.Motion.quick) { isHovering = hovering }
        }
    }
}
