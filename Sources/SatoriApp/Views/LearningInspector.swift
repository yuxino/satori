import AppKit
import SwiftUI
import SatoriCore
import UniformTypeIdentifiers

struct LearningInspector: View {
    /// The learning panel has no parallel tabs. It flows: default is the ask
    /// space; selecting code flips it to run; the notes button overlays the
    /// book's notes on demand. One space at a time, driven by the reader's
    /// action — not by a tab they have to remember to switch.
    enum ContextScope: Equatable {
        case selection
        case page
        case wholeDocument

        var pickerTitle: String {
            switch self {
            case .selection: "选中内容"
            case .page: "当前页"
            case .wholeDocument: "整本书"
            }
        }

        var systemImage: String {
            switch self {
            case .selection: "text.cursor"
            case .page: "doc.text"
            case .wholeDocument: "books.vertical"
            }
        }
    }

    let documentID: UUID
    let pageIndex: Int
    let selectedText: String
    let selectionCommand: SelectionCommand?
    let documentURL: URL
    let onNavigateToPage: (Int) -> Void
    let onClose: () -> Void

    @Environment(\.openSettings) private var openSettings
    @Environment(\.scenePhase) private var scenePhase
    @State private var showsNotes = false
    @State private var isShowingRun = false
    @State private var question = ""
    @State private var turns: [LearningTurn] = []
    @State private var expandedTurnIDs: Set<UUID> = []
    @State private var draftQuestion = ""
    @State private var draftPageIndex = 0
    @State private var draftAttachmentCount = 0
    @State private var response: LearningResponse?
    @State private var isThinking = false
    @State private var isLoadingHistory = true
    @State private var historyStatus = ""
    @State private var hasQwenConfiguration = false
    @State private var isCheckingConfiguration = false
    @State private var allowsWebSearch = false
    @State private var attachments: [LearningImageAttachment] = []
    @State private var isImportingImage = false
    @State private var attachmentStatus = ""
    @State private var contextScope: ContextScope = .page
    /// Selection text pinned from a PDF toolbar command. Used when the live PDF
    /// selection has already been cleared by the button click.
    @State private var pinnedSelectionText = ""
    @FocusState private var isQuestionFocused: Bool
    @State private var requestTask: Task<Void, Never>?
    @State private var showsClearConfirmation = false

    // MARK: Run space (quick code execution)

    @State private var runCode = ""
    @State private var runLanguage: CodeRunner.Language = .python
    @State private var runOutput: CodeRunResult?
    @State private var isRunning = false

    private let sessionStore = LearningSessionStore.shared
    private let reviewStore = ReviewStore.shared
    private let responseBottomID = "learning-response-bottom"
    private let quickPrompts = [
        "这一页主要在讲什么？",
        "用更简单的话解释",
        "给我一个具体例子"
    ]

    // MARK: Review (spaced retrieval)

    @State private var reviewQuestions: [ReviewQuestion] = []
    @State private var isGeneratingReview = false
    @State private var isReviewing = false
    @State private var reviewIndex = 0
    @State private var isAnswerRevealed = false
    @State private var reviewTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            inspectorHeader
            Divider()

            if showsNotes {
                notesView
            } else if isShowingRun {
                runView
            } else {
                askView
            }
        }
        .background(SatoriTheme.paper)
        .task(id: documentID) { await loadHistory() }
        .task(id: documentID) { await loadDueReviews() }
        .onAppear { refreshConfigurationState() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refreshConfigurationState() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .qwenConfigurationDidChange)) { _ in
            refreshConfigurationState()
        }
        .onChange(of: selectionCommand) { _, command in
            handleSelectionCommand(command)
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
    }

    private var inspectorHeader: some View {
        HStack(spacing: SatoriTheme.Spacing.sm) {
            Text("这本书")
                .font(.headline)
            Spacer()

            // 笔记 is a temporary overlay, not a parallel space: a click shows
            // the book's notes and a click (or any ask/run action) returns.
            Button {
                withAnimation(SatoriTheme.Motion.quick) { showsNotes.toggle() }
            } label: {
                Label("笔记", systemImage: "book.pages")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(showsNotes ? SatoriTheme.accent : .secondary)

            Button("关闭", systemImage: "xmark", action: onClose)
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("关闭学习面板")
        }
        .padding(.horizontal, SatoriTheme.Spacing.lg)
        .padding(.vertical, SatoriTheme.Spacing.md)
        .background(SatoriTheme.paperRaised.opacity(0.6))
        .overlay(alignment: .bottom) { Divider() }
    }

    /// 问 — the page you're reading, its Q&A, and the composer. Nothing else.
    private var askView: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: SatoriTheme.Spacing.lg) {
                        askScopeHeader

                        if isLoadingHistory {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("正在载入这本书的学习记录…")
                            }
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 18)
                        } else if turns.isEmpty, draftQuestion.isEmpty {
                            promptStarter
                        } else {
                            if !currentPageHasNotes {
                                currentPageInvitation
                            }
                            currentPageTurns
                        }

                        if !draftQuestion.isEmpty, let response {
                            draftTurnCard(response)
                                .id("streaming-draft")
                        }

                        if !historyStatus.isEmpty {
                            Label(historyStatus, systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Color.clear
                            .frame(height: 1)
                            .id(responseBottomID)
                    }
                    .padding(SatoriTheme.Spacing.lg)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: response?.text) { _, _ in
                    proxy.scrollTo(responseBottomID, anchor: .bottom)
                }
                .onChange(of: turns.count) { _, _ in
                    proxy.scrollTo(responseBottomID, anchor: .bottom)
                }
            }

            Divider()
            composer
        }
    }

    /// The turn cards for the page currently on screen.
    private var currentPageTurns: some View {
        let current = turns.filter { $0.pageIndex == pageIndex }
        return VStack(alignment: .leading, spacing: SatoriTheme.Spacing.lg) {
            ForEach(current) { turn in
                learningTurnCard(turn)
                    .id(turn.id)
            }
        }
    }

    /// 笔记 — every page's Q&A, organized by page. Read-only browse of what
    /// was learned; no composer, no scope picker, no distractions.
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

    /// 复习 — self-testing with spaced retrieval. Own the whole space so due
    /// questions and the active session don't collide with reading.
    private var reviewView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: SatoriTheme.Spacing.lg) {
                if isReviewing {
                    reviewSessionView
                } else if isGeneratingReview {
                    HStack(spacing: SatoriTheme.Spacing.sm) {
                        ProgressView().controlSize(.small)
                        Text("正在根据这一页生成自测题…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, SatoriTheme.Spacing.sm)
                } else if !reviewQuestions.isEmpty {
                    reviewPromptView
                } else {
                    reviewEmptyView
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
                            withAnimation(SatoriTheme.Motion.quick) { isShowingRun = false }
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
        Task {
            let result = await CodeRunner.run(code: code, language: language)
            await MainActor.run {
                runOutput = result
                isRunning = false
            }
        }
    }

    private func stopRunning() {
        // A running snippet has no cancellable handle exposed; the timeout is
        // the backstop. Flip the flag so the next run is allowed immediately.
        isRunning = false
    }

    /// The review space's empty state — explains what this tab is for and
    /// offers to generate a first batch from the current page.
    private var reviewEmptyView: some View {
        VStack(spacing: SatoriTheme.Spacing.lg) {
            Image(systemName: "arrow.counterclockwise")
                .font(.system(size: 32))
                .foregroundStyle(SatoriTheme.gold)
            VStack(spacing: SatoriTheme.Spacing.xs + 1) {
                Text("把读过的东西记住")
                    .font(.title3.weight(.semibold))
                Text("Satori 会根据第 \(pageIndex + 1) 页和你的问答出几道题，\n先回想、再对答案。忘记的很快回来，记住的越隔越久。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button("考考我这一页", systemImage: "questionmark.circle") { startReview() }
                .buttonStyle(.borderedProminent)
                .tint(SatoriTheme.accent)
                .disabled(isGeneratingReview)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, SatoriTheme.Spacing.xxl)
    }

    /// The passage "选中内容" asks about: the live PDF highlight when there is
    /// one, otherwise the text pinned from a selection-toolbar command.
    private var activeSelection: String {
        let live = ExtractedTextNormalizer.normalize(selectedText)
        return live.isEmpty ? pinnedSelectionText : live
    }

    private var hasSelection: Bool {
        !activeSelection.isEmpty
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
        return grouped.keys.sorted().map { PageSection(pageIndex: $0, turns: grouped[$0] ?? []) }
    }

    /// Whether the page currently on screen already has notes — when it does,
    /// the "invitation to ask" belongs to that page instead of floating on top.
    /// A streaming draft counts too, so the invitation doesn't contradict an
    /// answer that is already being written for this page.
    private var currentPageHasNotes: Bool {
        turns.contains { $0.pageIndex == pageIndex }
            || (response != nil && draftPageIndex == pageIndex)
    }

    private var availableScopes: [ContextScope] {
        hasSelection ? [.selection, .page, .wholeDocument] : [.page, .wholeDocument]
    }

    /// A compact header for the ask space: what the next question is grounded
    /// in (selection / page / whole book). No buttons — this space is only
    /// about asking.
    private var askScopeHeader: some View {
        VStack(alignment: .leading, spacing: SatoriTheme.Spacing.sm) {
            Picker("提问依据", selection: $contextScope) {
                ForEach(availableScopes, id: \.self) { scope in
                    Label(scope.pickerTitle, systemImage: scope.systemImage).tag(scope)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            HStack(spacing: SatoriTheme.Spacing.sm) {
                Image(systemName: scopeIcon)
                    .font(.caption)
                    .foregroundStyle(SatoriTheme.iconChrome)
                Text(scopeSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            if contextScope == .selection, hasSelection {
                Text(activeSelection)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .padding(9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(SatoriTheme.Spacing.md)
        .background(SatoriTheme.paperRaised.opacity(0.8), in: RoundedRectangle(cornerRadius: SatoriTheme.Radius.md, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: SatoriTheme.Radius.md, style: .continuous).strokeBorder(SatoriTheme.hairline))
        .onChange(of: hasSelection) { _, selecting in
            if selecting {
                contextScope = .selection
            } else if contextScope == .selection {
                contextScope = .page
            }
        }
    }

    private var scopeIcon: String {
        switch contextScope {
        case .selection: "text.cursor"
        case .page: "doc.text"
        case .wholeDocument: "books.vertical"
        }
    }

    private var scopeSummary: String {
        switch contextScope {
        case .selection: "在 PDF 中选中的文字"
        case .page: "PDF 第 \(pageIndex + 1) 页"
        case .wholeDocument: "整本书的文字"
        }
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
                    QuickPromptButton(prompt: prompt) { askAssistant(prompt) }
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

    private func learningTurnCard(_ turn: LearningTurn) -> some View {
        let isExpanded = expandedTurnIDs.contains(turn.id)
        return VStack(alignment: .leading, spacing: SatoriTheme.Spacing.sm) {
            turnQuestionHeader(
                question: turn.question,
                pageIndex: turn.pageIndex,
                attachmentCount: turn.attachmentCount,
                createdAt: turn.createdAt,
                isExpanded: isExpanded,
                onToggle: { toggleTurn(turn.id) }
            )
            if isExpanded {
                Divider()
                answerHeader(
                    sourceKind: turn.sourceKind,
                    pageIndex: turn.pageIndex,
                    isStreaming: false,
                    completion: turn.completion
                )
                LearningMarkdownView(markdown: turn.answer)
                citationsView(turn.citations)
                turnActions(turn)
            }
        }
        .satoriPaper(radius: SatoriTheme.Radius.md, padding: SatoriTheme.Spacing.lg)
        .animation(SatoriTheme.Motion.standard, value: isExpanded)
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
                learningTurnCard(turn)
                    .id(turn.id)
            }
        }
    }

    /// Shown at the top when the page you're reading has no notes yet — a
    /// clear invitation to make the AI work on this page.
    private var currentPageInvitation: some View {
        VStack(alignment: .leading, spacing: SatoriTheme.Spacing.md) {
            HStack(spacing: SatoriTheme.Spacing.sm) {
                Image(systemName: "sparkles")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(SatoriTheme.gold)
                    .frame(width: 26, height: 26)
                    .background(SatoriTheme.goldWash, in: RoundedRectangle(cornerRadius: SatoriTheme.Radius.sm, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text("这一页还没有笔记")
                        .font(.callout.weight(.medium))
                    Text("第 \(pageIndex + 1) 页 · 让 AI 陪你读这一页")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            HStack(spacing: SatoriTheme.Spacing.sm) {
                ForEach(quickPrompts, id: \.self) { prompt in
                    Button {
                        askAssistant(prompt)
                    } label: {
                        Text(prompt)
                            .font(.callout)
                            .padding(.horizontal, SatoriTheme.Spacing.md)
                            .padding(.vertical, SatoriTheme.Spacing.sm)
                            .background(SatoriTheme.paperRaised, in: RoundedRectangle(cornerRadius: SatoriTheme.Radius.sm, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: SatoriTheme.Radius.sm, style: .continuous).strokeBorder(SatoriTheme.hairline))
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
        }
        .padding(SatoriTheme.Spacing.lg)
        .background(SatoriTheme.goldWash.opacity(0.5), in: RoundedRectangle(cornerRadius: SatoriTheme.Radius.md, style: .continuous))
    }

    /// A review question is due — invite the reader to self-test before it
    /// disappears from memory.
    private var reviewPromptView: some View {
        HStack(spacing: SatoriTheme.Spacing.md) {
            Image(systemName: "arrow.counterclockwise.circle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(SatoriTheme.gold)
            VStack(alignment: .leading, spacing: 1) {
                Text("该复习了")
                    .font(.callout.weight(.semibold))
                Text("有 \(reviewQuestions.count) 道题到期，先回想再对答案")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("开始复习") { isReviewing = true; reviewIndex = 0 }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(SatoriTheme.accent)
        }
        .padding(SatoriTheme.Spacing.md)
        .background(SatoriTheme.goldWash.opacity(0.5), in: RoundedRectangle(cornerRadius: SatoriTheme.Radius.md, style: .continuous))
    }

    /// The active self-test: one question at a time, reveal the answer, then
    /// rate how well it was recalled.
    private var reviewSessionView: some View {
        let question = reviewQuestions[reviewIndex]
        let isLast = reviewIndex == reviewQuestions.count - 1
        return VStack(alignment: .leading, spacing: SatoriTheme.Spacing.md) {
            HStack {
                Text("自测 · 第 \(pageIndex + 1) 页")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(reviewIndex + 1) / \(reviewQuestions.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }

            Text(question.question)
                .font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            if reviewIndex < reviewQuestions.count, isAnswerRevealed {
                VStack(alignment: .leading, spacing: SatoriTheme.Spacing.sm) {
                    Text("答案")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(question.answer)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .padding(SatoriTheme.Spacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(SatoriTheme.accentWash.opacity(0.5), in: RoundedRectangle(cornerRadius: SatoriTheme.Radius.sm, style: .continuous))
            }

            if isAnswerRevealed {
                VStack(spacing: SatoriTheme.Spacing.sm) {
                    Text("你回想得怎么样？")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: SatoriTheme.Spacing.sm) {
                        ForEach(ReviewRating.allCases, id: \.self) { rating in
                            Button(rating.localizedTitle) {
                                rateCurrentReview(rating)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                        Spacer()
                    }
                }
            } else {
                HStack {
                    Button("先回想，再对答案") { revealAnswer() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .tint(SatoriTheme.accent)
                    Spacer()
                    Button("放弃这次复习") { stopReview() }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(SatoriTheme.Spacing.lg)
        .satoriPaper(radius: SatoriTheme.Radius.md, padding: SatoriTheme.Spacing.lg)
        .id(question.id)
        .transition(.opacity.combined(with: .move(edge: .trailing)))
        .animation(SatoriTheme.Motion.standard, value: reviewIndex)
        .onAppear { isAnswerRevealed = false }
    }

    private func draftTurnCard(_ draftResponse: LearningResponse) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            turnQuestionHeader(
                question: draftQuestion,
                pageIndex: draftPageIndex,
                attachmentCount: draftAttachmentCount,
                createdAt: .now,
                isExpanded: nil,
                onToggle: nil
            )
            Divider()
            answerHeader(
                sourceKind: draftResponse.sourceKind,
                pageIndex: draftPageIndex,
                isStreaming: isThinking,
                completion: .completed
            )
            if draftResponse.text.isEmpty {
                HStack(spacing: SatoriTheme.Spacing.sm) {
                    ProgressView().controlSize(.small)
                    Text(allowsWebSearch ? "正在理解原文并检索资料…" : "正在理解当前页…")
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
                .padding(.vertical, SatoriTheme.Spacing.xs + 2)
            } else {
                LearningMarkdownView(markdown: draftResponse.text)
            }
            citationsView(draftResponse.citations)
            if !isThinking, draftResponse.sourceKind == .inference {
                HStack {
                    if !hasQwenConfiguration {
                        Button("连接 Qwen", systemImage: "key") { openSettings() }
                            .buttonStyle(.borderless)
                    }
                    Spacer()
                    Button("重试", systemImage: "arrow.clockwise") {
                        askAssistant(draftQuestion, pageOverride: draftPageIndex)
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        .satoriPaper(radius: SatoriTheme.Radius.md, padding: SatoriTheme.Spacing.lg, emphasized: isThinking)
    }

    private func turnQuestionHeader(
        question: String,
        pageIndex: Int,
        attachmentCount: Int,
        createdAt: Date,
        isExpanded: Bool?,
        onToggle: (() -> Void)?
    ) -> some View {
        VStack(alignment: .leading, spacing: SatoriTheme.Spacing.sm) {
            HStack {
                Text(question)
                    .font(.body.weight(.semibold))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                if let isExpanded, let onToggle {
                    Button(isExpanded ? "收起回答" : "展开回答", systemImage: isExpanded ? "chevron.up" : "chevron.down") {
                        withAnimation(SatoriTheme.Motion.standard) { onToggle() }
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(isExpanded ? "收起回答" : "展开回答")
                }
            }
            HStack(spacing: SatoriTheme.Spacing.sm) {
                Button("第 \(pageIndex + 1) 页") { onNavigateToPage(pageIndex) }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .help("回到这一页")
                if attachmentCount > 0 {
                    Label("\(attachmentCount) 张附图", systemImage: "photo.on.rectangle.angled")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(createdAt, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func answerHeader(
        sourceKind: LearningSourceKind,
        pageIndex: Int,
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
            Text("依据第 \(pageIndex + 1) 页")
                .font(.caption2)
                .foregroundStyle(.tertiary)
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

    private func turnActions(_ turn: LearningTurn) -> some View {
        HStack(spacing: 12) {
            Spacer()
            Button("复制", systemImage: "doc.on.doc") { copyToPasteboard(turn.answer) }
                .buttonStyle(.borderless)
            Button("重试", systemImage: "arrow.clockwise") {
                onNavigateToPage(turn.pageIndex)
                askAssistant(turn.question, pageOverride: turn.pageIndex, excludingTurnID: turn.id)
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

            ZStack(alignment: .topLeading) {
                if question.isEmpty {
                    Text(turns.isEmpty ? "问这一页，也可以附上图片…" : "继续追问这里为什么、再举个例子…")
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
                    withAnimation(SatoriTheme.Motion.quick) {
                        isShowingRun = true
                        showsNotes = false
                    }
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
        let scope: String
        switch contextScope {
        case .selection: scope = "选中内容"
        case .page: scope = "当前页"
        case .wholeDocument: scope = "整本书"
        }
        let web = allowsWebSearch ? "、联网" : ""
        return "Enter 发送 · Shift+Enter 换行 · ⌘V 贴图 · 依据\(scope)、最近对话、附件\(web)"
    }

    @MainActor
    private func loadHistory() async {
        isLoadingHistory = true
        historyStatus = ""
        do {
            turns = try await sessionStore.turns(for: documentID)
            expandedTurnIDs = Set(turns.last.map { [$0.id] } ?? [])
        } catch {
            turns = []
            historyStatus = "学习记录暂时无法读取；不影响继续阅读和提问。"
        }
        isLoadingHistory = false
    }

    private func askAssistant(
        _ suppliedQuestion: String? = nil,
        pageOverride: Int? = nil,
        selectionOverride: String? = nil,
        excludingTurnID: UUID? = nil
    ) {
        let request = (suppliedQuestion ?? question).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty, !isThinking else { return }

        let targetPageIndex = pageOverride ?? pageIndex
        // Retries carry a page override and always re-ask against that page;
        // a selection override comes from the PDF toolbar's "解释这段"; fresh
        // questions otherwise follow whatever scope the reader picked.
        let effectiveScope: ContextScope
        if selectionOverride != nil {
            effectiveScope = .selection
        } else if pageOverride != nil {
            effectiveScope = .page
        } else {
            effectiveScope = contextScope
        }
        let extractionScope: PDFPageContextExtractor.Scope
        switch effectiveScope {
        case .selection:
            extractionScope = .selection(selectionOverride ?? activeSelection)
        case .page:
            extractionScope = .page(targetPageIndex)
        case .wholeDocument:
            extractionScope = .wholeDocument
        }

        guard let pageContent = PDFPageContextExtractor.extract(from: documentURL, scope: extractionScope) else {
            draftQuestion = request
            draftPageIndex = targetPageIndex
            response = LearningResponse(
                text: scopeExtractionFailureMessage(effectiveScope, pageIndex: targetPageIndex),
                sourceKind: .inference,
                pageIndex: targetPageIndex
            )
            return
        }

        let submittedAttachments = attachments
        let context = turns
            .filter { $0.id != excludingTurnID }
            .suffix(6)
            .map { LearningConversationContext(question: $0.question, answer: $0.answer) }

        draftQuestion = request
        draftPageIndex = targetPageIndex
        draftAttachmentCount = submittedAttachments.count
        question = ""
        attachments = []
        attachmentStatus = ""
        response = LearningResponse(text: "", sourceKind: .currentPDF, pageIndex: targetPageIndex)
        isThinking = true

        requestTask = Task {
            let configuration = await Task.detached(priority: .userInitiated) {
                QwenConfigurationStore.read()
            }.value
            if Task.isCancelled { return }
            guard let configuration else {
                hasQwenConfiguration = false
                isThinking = false
                requestTask = nil
                response = LearningResponse(
                    text: "请先在设置中连接 Qwen。百炼 API Key 只会保存在这台 Mac 的钥匙串中。",
                    sourceKind: .inference,
                    pageIndex: targetPageIndex
                )
                return
            }
            hasQwenConfiguration = true
            let assistant = QwenLearningAssistant(
                apiKey: configuration.apiKey,
                modelID: configuration.modelID,
                pageContent: pageContent,
                additionalImagesJPEG: submittedAttachments.map(\.jpegData),
                conversationContext: context,
                allowsWebSearch: allowsWebSearch
            )
            var latestResponse: LearningResponse?
            for await update in assistant.streamExplain(request: request, pageIndex: targetPageIndex) {
                if Task.isCancelled { return }
                latestResponse = update
                response = update
            }
            if Task.isCancelled { return }
            isThinking = false
            requestTask = nil
            guard let latestResponse else { return }
            if latestResponse.sourceKind == .inference {
                response = latestResponse
            } else {
                completeDraft(with: latestResponse, completion: .completed)
            }
        }
    }

    /// Reacts to a Cursor-style command from the PDF selection toolbar.
    /// "解释这段" asks immediately; "就这段提问" pins the passage and lets the
    /// reader type.
    private func handleSelectionCommand(_ command: SelectionCommand?) {
        guard let command else { return }
        let text = ExtractedTextNormalizer.normalize(command.text)
        guard !text.isEmpty else { return }

        pinnedSelectionText = text
        contextScope = .selection

        switch command.action {
        case .explain:
            showsNotes = false
            isShowingRun = false
            askAssistant("解释我选中的这段内容", selectionOverride: text)
        case .compose:
            showsNotes = false
            isShowingRun = false
            isQuestionFocused = true
        }
    }

    /// Loads the due review questions for this book so the panel can surface
    /// "该复习了" when spaced repetition says it's time. Reading the store is
    /// local, so it works regardless of Qwen configuration.
    @MainActor
    private func loadDueReviews() async {
        do {
            reviewQuestions = try await reviewStore.dueQuestions(for: documentID)
        } catch {
            reviewQuestions = []
        }
    }

    /// Asks the AI to generate retrieval-practice questions for the current
    /// page, then starts the review session.
    private func startReview() {
        guard !isGeneratingReview, !isReviewing else { return }
        let targetPage = pageIndex
        guard let pageContent = PDFPageContextExtractor.extract(from: documentURL, scope: .page(targetPage)) else {
            historyStatus = "暂时无法读取这一页，无法出题。"
            return
        }
        isGeneratingReview = true
        reviewTask = Task {
            defer { isGeneratingReview = false }
            let configuration = await Task.detached(priority: .userInitiated) {
                QwenConfigurationStore.read()
            }.value
            guard let configuration else {
                hasQwenConfiguration = false
                historyStatus = "请先在设置中连接 Qwen，才能生成复习题。"
                return
            }
            hasQwenConfiguration = true
            let assistant = QwenLearningAssistant(
                apiKey: configuration.apiKey,
                modelID: configuration.modelID,
                pageContent: pageContent,
                conversationContext: turns
                    .filter { $0.pageIndex == targetPage }
                    .suffix(4)
                    .map { LearningConversationContext(question: $0.question, answer: $0.answer) }
            )
            let questions = await assistant.generateReviewQuestions(pageIndex: targetPage, count: 3)
            guard !questions.isEmpty else {
                historyStatus = "AI 没能生成题目，请稍后再试。"
                return
            }
            reviewQuestions = questions
            isReviewing = true
            reviewIndex = 0
        }
    }

    private func rateCurrentReview(_ rating: ReviewRating) {
        guard reviewIndex < reviewQuestions.count else { return }
        let question = reviewQuestions[reviewIndex]
        Task {
            try? await reviewStore.rate(for: documentID, question: question, rating: rating)
            await MainActor.run {
                withAnimation(SatoriTheme.Motion.quick) {
                    if reviewIndex + 1 < reviewQuestions.count {
                        reviewIndex += 1
                    } else {
                        reviewQuestions = []
                        isReviewing = false
                    }
                }
            }
        }
    }

    private func stopReview() {
        reviewTask?.cancel()
        reviewTask = nil
        isReviewing = false
        isGeneratingReview = false
        reviewQuestions = []
    }

    private func revealAnswer() {
        withAnimation(SatoriTheme.Motion.quick) { isAnswerRevealed = true }
    }

    private func scopeExtractionFailureMessage(_ scope: ContextScope, pageIndex: Int) -> String {
        switch scope {
        case .selection: "没有读到选中的文字。请在 PDF 里重新划选一段再提问。"
        case .page: "暂时无法读取第 \(pageIndex + 1) 页。请确认 PDF 文件仍然可以打开。"
        case .wholeDocument: "这本书里没有可提取的文字（可能是扫描版）。可以改用“当前页”，Satori 会把该页作为图片交给 AI。"
        }
    }

    private func stopAssistant() {
        requestTask?.cancel()
        requestTask = nil
        isThinking = false
        guard let response, !response.text.isEmpty, response.sourceKind != .inference else {
            self.response = LearningResponse(text: "已停止这次回答。", sourceKind: .inference, pageIndex: draftPageIndex)
            return
        }
        completeDraft(with: response, completion: .stopped)
    }

    private func completeDraft(with finalResponse: LearningResponse, completion: LearningTurnCompletion) {
        let turn = LearningTurn(
            question: draftQuestion,
            answer: finalResponse.text,
            pageIndex: draftPageIndex,
            sourceKind: finalResponse.sourceKind,
            citations: finalResponse.citations,
            attachmentCount: draftAttachmentCount,
            completion: completion
        )
        turns.append(turn)
        expandedTurnIDs = [turn.id]
        draftQuestion = ""
        draftAttachmentCount = 0
        response = nil
        persistTurns()
    }

    private func deleteTurn(_ turnID: UUID) {
        turns.removeAll { $0.id == turnID }
        expandedTurnIDs.remove(turnID)
        persistTurns()
    }

    private func clearHistory() {
        requestTask?.cancel()
        requestTask = nil
        isThinking = false
        turns = []
        expandedTurnIDs = []
        draftQuestion = ""
        response = nil
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
        let pasted = LearningImageAttachmentLoader.load(from: .general)
        guard !pasted.isEmpty else { return false }

        let remaining = max(0, 4 - attachments.count)
        guard remaining > 0 else {
            attachmentStatus = "每次最多附加 4 张图片，粘贴的图片没有加入。"
            return true
        }
        attachments.append(contentsOf: pasted.prefix(remaining))
        attachmentStatus = pasted.count > remaining ? "每次最多附加 4 张图片，其余图片没有加入。" : ""
        return true
    }

    private func importImages(_ result: Result<[URL], Error>) {
        do {
            let urls = try result.get()
            let remaining = max(0, 4 - attachments.count)
            let selected = Array(urls.prefix(remaining))
            attachments.append(contentsOf: try selected.map(LearningImageAttachmentLoader.load))
            attachmentStatus = urls.count > remaining ? "每次最多附加 4 张图片，其余图片没有加入。" : ""
        } catch CocoaError.userCancelled {
            attachmentStatus = ""
        } catch {
            attachmentStatus = error.localizedDescription
        }
    }

    private func toggleTurn(_ turnID: UUID) {
        if expandedTurnIDs.contains(turnID) {
            expandedTurnIDs.remove(turnID)
        } else {
            expandedTurnIDs.insert(turnID)
        }
    }

    private func refreshConfigurationState() {
        let markedAsConfigured = QwenConfigurationStore.hasSavedConfigurationMarker()
        hasQwenConfiguration = markedAsConfigured
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
