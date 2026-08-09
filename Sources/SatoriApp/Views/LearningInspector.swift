import AppKit
import SwiftUI
import SatoriCore
import UniformTypeIdentifiers

struct LearningInspector: View {
    /// The learning panel has three mutually exclusive spaces (⌘1-3): 问 is the
    /// default ask space; 回看 browses the book's saved Q&A by page; 运行 is the
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
            case .notes: "回看"
            case .run: "实验"
            }
        }

        var systemImage: String {
            switch self {
            case .ask: "bubble.left.and.text.bubble.right"
            case .notes: "book.pages"
            case .run: "testtube.2"
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


    /// 提问时参考的上下文：默认按问题措辞智能选择，普通问题回到当前页；
    /// 需要时仍可主动切换到章节、整本书或无上下文。
    enum ContextMode: String, CaseIterable, Identifiable {
        case automatic
        case none
        case page
        case chapter
        case pageRange
        case wholeDocument

        var id: String { rawValue }
    }

    /// 一轮回答的准备阶段；把本地取材和模型首字等待分开，用户才知道
    /// 是 Satori 还在读 PDF，还是 Qwen 已收到请求但尚未开始输出。
    private enum RequestPhase: Equatable {
        case loadingConfiguration
        case preparing
        case waitingForFirstToken
        case streaming
    }

    let documentID: UUID
    let pageIndex: Int
    let currentPageOffset: Double
    let pageCount: Int
    let documentURL: URL
    /// 这本书的章节导览（PDF outline 优先，课程目录回退）；为空时「章节」选项隐藏。
    let chapters: [BookChapter]
    /// Scanned books recover chapter boundaries asynchronously. Chapter-wide
    /// questions must wait for that result instead of silently becoming a
    /// current-page question.
    let isLoadingChapters: Bool
    /// Returns the textbook's printed page for a PDF page when a local map is
    /// available. Scanned and native books can use different mapping sources.
    let printedPageForPage: (Int) -> Int?
    let onNavigateToPage: (Int) -> Void
    let onClose: () -> Void

    @Environment(\.openSettings) private var openSettings
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var router: ReaderSelectionRouter
    @State private var mode: InspectorMode = .ask
    @State private var question = ""
    /// 发送问题时给 AI 的上下文：默认按问题措辞智能选择，避免每次提问前先配置范围。
    /// 默认让 Satori 从问题措辞判断需要当前页、前后页还是章节；
    /// 用户在菜单里选定具体范围后，自动判断就让位给明确选择。
    @State private var contextMode: ContextMode = .automatic
    /// 「多页」范围（1 起，UI 显示用；发送时转成 0 起）。
    @State private var rangeStart = 1
    @State private var rangeEnd = 1
    /// 「章节」上下文里用户选中的章节 id；nil 表示跟随当前章节。
    @State private var selectedChapterID: Int?
    /// 上次选区所在页：用于用户继续追问时保持原文附近的上下文；
    /// 用户翻页后失效。
    @State private var pendingSelectionPage: Int?
    /// 当前正在理解的原文锚点。它不替代持久化问答，只负责让阅读现场
    /// 在回答过程中保持可见，并提供一键返回原文。
    @State private var activeSelectionText: String?
    @State private var activeSelectionPage: Int?
    @State private var activeSelectionOffset: Double?
    /// 扫描页框选的视觉锚点。图片只在内存中保留，后续追问会按页码和
    /// 归一化矩形重新带回同一块区域，避免同页多个代码示例串台。
    @State private var activeRegionAnchor: ReadingRegionAnchor?
    @State private var activeRegionAttachment: LearningImageAttachment?
    @State private var turns: [LearningTurn] = []
    @State private var draftQuestion = ""
    @State private var draftPageIndex = 0
    @State private var draftContextScope: LearningContextScope = .none
    @State private var draftAttachmentCount = 0
    /// 当前草稿关联的选区；即使用户清掉可视锚点，重试也不能丢掉原文。
    @State private var draftSelectionText: String?
    @State private var draftSelectionOffset: Double?
    @State private var draftRegionAnchor: ReadingRegionAnchor?
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
    /// 每次新问题或历史加载完成时递增，强制 ScrollViewReader 执行一次滚动。
    /// 不能只依赖 scrollPosition 的 ID：连续提问时 ID 可能没有变化。
    @State private var scrollRequest = 0
    @State private var hasQwenConfiguration = false
    @State private var isCheckingConfiguration = false
    @State private var allowsWebSearch = false
    /// 本轮实际是否会联网；可能由用户开关触发，也可能由“找资料/查最新”等
    /// 明确意图自动触发，但不会永久改变下一轮的开关状态。
    @State private var requestUsesWebSearch = false
    @State private var completedElsewherePage: Int?
    /// 最近完成的一轮问答所属页；如果 PDF 在归档后才跨过页边界，
    /// 仍要给用户一次明确的落点提示，避免当前页过滤让回答像没发生过。
    @State private var recentCompletedPage: Int?
    /// 新翻到、还没有问答的页面只显示一次轻量入口；用户不想要时可收起，
    /// 避免在已有对话旁边重复堆快捷功能。
    @State private var dismissedPageEntryPage: Int?
    /// Scanned textbooks often reopen on a foreword or exam-outline page.
    /// Keep the shortcut to the first real chapter available once, then get
    /// out of the reader's way for the rest of the front matter.
    @State private var dismissedFrontMatterEntry = false
    @State private var attachments: [LearningImageAttachment] = []
    /// 发送中的这一轮贴的图（用于对话里即时展示缩略图；归档后历史只记张数）。
    @State private var activeAttachmentPreviews: [NSImage] = []
    /// 输入框图片在请求期间的临时保管区。停止或取材失败时还给用户，
    /// 避免扫描页框选后因为一次等待/失败就丢掉唯一的视觉证据。
    @State private var submittedAttachmentsForActiveRequest: [LearningImageAttachment] = []
    @State private var isImportingImage = false
    @State private var attachmentStatus = ""
    /// A natural chapter question submitted while scanned-outline recovery is
    /// still running. The text remains in the composer and is sent exactly
    /// once when chapter boundaries become available.
    @State private var pendingChapterMetadataQuestion: String?
    /// 这一轮回答开始的时间；只在流式等待期间提示是否仍在工作。
    @State private var streamStartDate: Date?
    @State private var requestPhase: RequestPhase = .preparing
    /// 验证提示回答完成后，下一次输入应被理解为用户自己的回答；
    /// 它只存在于当前阅读现场，不把 Satori 变成强制测验系统。
    @State private var pendingVerification = false
    /// The student's answer must use the same evidence window that produced
    /// the verification scenario. Otherwise a two-page bridge silently
    /// collapses to the current page while the student is being evaluated.
    @State private var pendingVerificationScope: LearningContextScope?
    /// Increments on every page change so a slow verification response cannot
    /// resurrect its prompt after the reader has left and returned.
    @State private var readingPositionRevision = 0
    @State private var draftPageRevision = 0
    /// 只有用户明确点了「回答」才进入验证回答模式；普通追问不应被误判。
    @State private var verificationAnswerMode = false
    @State private var draftIsVerification = false
    @FocusState private var isQuestionFocused: Bool
    @State private var requestTask: Task<Void, Never>?
    @State private var showsClearConfirmation = false

    // MARK: Run space (quick code execution)

    @State private var runCode = ""
    @State private var runStandardInput = ""
    @State private var runLanguage: CodeRunner.Language = .python
    @State private var runSourcePage: Int?
    @State private var runOutput: CodeRunResult?
    @State private var isRunning = false
    @State private var runTask: Task<Void, Never>?
    @State private var runNotice = ""

    private let sessionStore = LearningSessionStore.shared
    private let responseBottomID = "learning-response-bottom"
    private let quickPrompts = [
        "这一页最重要的一个意思是什么？",
        "它在解决什么问题？",
        "给我一个具体例子"
    ]
    private static let maxSelectionCharacters = 4_000

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
        .onAppear {
            refreshConfigurationState()
            // Selection actions leave immersive mode in ContentView before the
            // panel mounts. Keep this fallback for an already queued request,
            // such as one delivered during a layout transition.
            consumePendingRouterRequests()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refreshConfigurationState() }
        }
        .onChange(of: isLoadingChapters) { wasLoading, isLoading in
            guard wasLoading, !isLoading,
                  let pendingQuestion = pendingChapterMetadataQuestion else { return }
            pendingChapterMetadataQuestion = nil
            guard question.trimmingCharacters(in: .whitespacesAndNewlines) == pendingQuestion else {
                return
            }
            guard canResolveChapterScope(for: pendingQuestion) else {
                attachmentStatus = "没有识别出这章的页码范围；请在“智能范围”里选择多页后再发送。"
                return
            }
            attachmentStatus = ""
            askAssistant()
        }
        .onReceive(NotificationCenter.default.publisher(for: .qwenConfigurationDidChange)) { _ in
            refreshConfigurationState()
        }

        // PDFReaderView 只负责发出通知，ContentView 将它转换为 typed
        // request；这里消费 Router，因此沉浸模式下的选区动作不会丢失。
        .onChange(of: router.pendingAskSelection) { _, request in
            guard let request, !router.isImmersiveReading else { return }
            router.pendingAskSelection = nil
            handleSelection(request)
        }
        .onChange(of: router.pendingRunSelection) { _, request in
            guard let request, !router.isImmersiveReading else { return }
            router.pendingRunSelection = nil
            handleRunSelection(request)
        }
        .onChange(of: router.pendingPageRegion?.id) { _, _ in
            consumePendingRouterRequests()
        }
        .fileImporter(
            isPresented: $isImportingImage,
            allowedContentTypes: [.image],
            allowsMultipleSelection: true,
            onCompletion: importImages
        )
        .alert("清空这本书的问答记录？", isPresented: $showsClearConfirmation) {
            Button("取消", role: .cancel) {}
            Button("清空记录", role: .destructive, action: clearHistory)
        } message: {
            Text("只会删除本机保存的 AI 问答，不会影响 PDF、阅读位置或百炼账户。")
        }
        .onDisappear {
            requestTask?.cancel()
            // Closing the panel or switching books must also stop a running
            // micro-experiment. Otherwise the UI disappears while the local
            // process keeps consuming resources in the background.
            stopRunning()
        }
        .onChange(of: pageIndex) { _, newPageIndex in
            readingPositionRevision += 1
            if let recentCompletedPage, recentCompletedPage != newPageIndex {
                completedElsewherePage = recentCompletedPage
                self.recentCompletedPage = nil
            }
            // 用户翻页后，之前选中的上下文不再指向当前阅读位置。
            pendingSelectionPage = nil
            dismissedPageEntryPage = nil
            // A verification prompt belongs to the page that produced it.
            // Once the reader moves on, the next question is a normal reading
            // question—not an answer to an old prompt.
            pendingVerification = false
            pendingVerificationScope = nil
            verificationAnswerMode = false
            // 章节选择自动同步阅读位置：只有离开当前顶层章才取消手动选择。
            // 旧逻辑拿最深的小节比较，导致用户选了“第六章”后翻到
            // “（2）磁盘”就被悄悄清掉，下一问又缩回小节范围。
            if let selectedChapterID,
               let selected = chapters.first(where: { $0.id == selectedChapterID }),
               let selectedTopLevel = topLevelChapter(for: selected),
               selectedTopLevel.id != currentTopLevelChapter?.id {
                self.selectedChapterID = nil
            }
        }
    }

    private func handleSelection(_ request: ReaderSelectionRequest) {
        let text = normalizedSelectionText(request.text)
        guard request.documentID == documentID,
              !text.isEmpty,
              request.url == nil || request.url == documentURL else { return }

        selectMode(.ask)
        pendingSelectionPage = request.pageIndex
        activeSelectionText = text
        activeSelectionPage = request.pageIndex
        activeSelectionOffset = request.position?.normalizedPageOffset
        if let previousRegionID = activeRegionAttachment?.id {
            attachments.removeAll { $0.id == previousRegionID }
        }
        activeRegionAnchor = nil
        activeRegionAttachment = nil
        let selectionContextScope = selectionScope(for: request.intent, pageIndex: request.pageIndex)
        let prompt = selectionPrompt(for: request.intent, pageIndex: request.pageIndex)
        if question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !isThinking {
            DispatchQueue.main.async {
                askAssistant(
                    prompt,
                    pageOverride: request.pageIndex,
                    scope: selectionContextScope,
                    selectionText: text,
                    selectionOffset: request.position?.normalizedPageOffset
                )
            }
        } else {
            // 用户已经在输入问题：把选区动作的上下文同步到可见选择器，
            // 让他知道下一次发送会带哪些页，也允许他继续手动覆盖范围。
            switch selectionContextScope {
            case let .pageRange(start, end):
                contextMode = .pageRange
                rangeStart = start + 1
                rangeEnd = end + 1
            default:
                contextMode = .page
            }
            // The selected passage is already carried as a separate, bounded
            // request item below. Keep only the intent in the editable draft;
            // duplicating the full passage here made long selections inflate
            // the prompt and weakened the reader's actual question.
            question += question.isEmpty ? prompt : "\n\n" + prompt
            DispatchQueue.main.async {
                isQuestionFocused = true
            }
        }
    }

    private func normalizedSelectionText(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > Self.maxSelectionCharacters else { return trimmed }
        return String(trimmed.prefix(Self.maxSelectionCharacters - 1)) + "…"
    }

    private func consumePendingRouterRequests() {
        guard !router.isImmersiveReading else { return }
        if let request = router.pendingAskSelection {
            router.pendingAskSelection = nil
            handleSelection(request)
        }
        if let request = router.pendingRunSelection {
            router.pendingRunSelection = nil
            handleRunSelection(request)
        }
        if let request = router.pendingPageRegion {
            guard !router.isImmersiveReading else { return }
            router.pendingPageRegion = nil
            handlePageRegion(request)
        }
    }

    private func handlePageRegion(_ request: ReaderPageRegionRequest) {
        guard request.documentID == documentID,
              request.url == nil || request.url == documentURL else { return }
        let replacingRegion = activeRegionAttachment != nil
        guard attachments.count < 4 || replacingRegion else {
            attachmentStatus = "每次最多附加 4 张图片，请先发送或移除一张。"
            return
        }
        guard let preview = NSImage(data: request.jpegData), preview.size.width > 0 else {
            attachmentStatus = "框选区域暂时无法读取，请再框选一次。"
            return
        }

        selectMode(.ask)
        // A visual crop is a new reading anchor. Do not silently carry a
        // stale native-text selection from the same page into this request;
        // otherwise a mixed PDF can make the answer explain two unrelated
        // objects at once. The user can still name the old passage in the
        // composer if they intentionally want a comparison.
        activeSelectionText = nil
        activeSelectionPage = nil
        activeSelectionOffset = nil
        let attachment = LearningImageAttachment(
            name: "\(readingPageLabel(request.pageIndex)) · 框选",
            jpegData: request.jpegData,
            preview: preview
        )
        let previousRegionID = activeRegionAttachment?.id
        activeRegionAnchor = request.anchor
        activeRegionAttachment = attachment
        // Put the current region first. Qwen receives this image immediately
        // after the explicit role marker, before any extra user attachments.
        if let previousRegionID {
            attachments.removeAll { $0.id == previousRegionID }
        }
        attachments.insert(attachment, at: 0)
        pendingSelectionPage = request.pageIndex
        attachmentStatus = "已框选\(readingPageLabel(request.pageIndex))的一块区域。"

        if question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !isThinking {
            question = "解释我刚框选的这部分内容，并说明它在这一页中起什么作用。"
            DispatchQueue.main.async {
                askAssistant()
            }
        } else {
            question += question.isEmpty ? "结合我框选的这部分回答。" : "\n\n结合我刚框选的这部分回答。"
            DispatchQueue.main.async {
                isQuestionFocused = true
            }
        }
    }

    private func handleRunSelection(_ request: ReaderSelectionRequest) {
        let text = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty,
              request.url == nil || request.url == documentURL else { return }
        selectMode(.run)
        runCode = text
        runStandardInput = ""
        runSourcePage = request.pageIndex
        runNotice = ""
        if let hintedLanguage = CodeRunner.languageHint(for: text) {
            // A direct PDF selection has no markdown fence to tell the
            // scratchpad whether this is C or Python. Infer it before the
            // reader sees the experiment, otherwise the default Python mode
            // makes a perfectly valid C example fail on the first click.
            runLanguage = hintedLanguage
        } else {
            runNotice = "暂未识别代码语言，已按 Python 载入；可在上方切换。"
        }
    }

    /// A reader who has already selected code often says only “运行”. Route
    /// that short action into the safe experiment space instead of spending a
    /// model turn explaining how terminals work. It never runs automatically;
    /// the reader reviews the snippet and presses Run explicitly.
    private func routeRunIntentIfPossible(for request: String) -> Bool {
        guard !pendingVerification,
              let code = activeSelectionText?.trimmingCharacters(in: .whitespacesAndNewlines),
              !code.isEmpty,
              let language = CodeRunner.languageHint(for: code),
              CodeRunner.isRunIntent(request) else { return false }
        selectMode(.run)
        runCode = code
        runStandardInput = ""
        runLanguage = language
        runSourcePage = activeSelectionPage
        runOutput = nil
        runNotice = ""
        question = ""
        pendingSelectionPage = nil
        return true
    }

    private var inspectorHeader: some View {
        VStack(spacing: SatoriTheme.Spacing.md) {
            HStack(spacing: SatoriTheme.Spacing.sm) {
                Text("理解现场")
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

    /// 问 / 回看 / 运行 — one active space, ⌘1-3.
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
            attachmentCount: draftAttachmentCount,
            contextScope: draftContextScope,
            selectionText: draftSelectionText,
            selectionOffset: draftSelectionOffset,
            selectionAnchorOffset: draftSelectionOffset,
            regionAnchor: draftRegionAnchor,
            attachmentNotice: response?.attachmentNotice
        )
    }

    private var isStreamingAnswer: Bool {
        isThinking && !draftQuestion.isEmpty
    }

    /// 问 — 当前阅读页的理解现场 + 输入框。完整历史留在「回看」，
    /// 但发送请求仍会携带最近几轮问答，让跨页追问不丢上下文。
    private var askView: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
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
                        } else if groundedTurns.isEmpty, activeTurn == nil {
                            // 第一次进入章节时，下面的 pageEntryPrompt 已经给出
                            // 唯一的阅读入口；不要再把通用快捷问题堆在上面。
                            if !showsPageEntry {
                                promptStarter
                            }
                        } else {
                            // 「问」只呈现当前页，避免翻到新页后被上一页的长回答
                            // 占满视野；完整的跨页记录仍可在「回看」里按页查看。
                            if currentPageTurns.isEmpty,
                               activeTurn == nil,
                               !showsPageEntry {
                                emptyPageHint
                            }
                            ForEach(currentPageTurns) { turn in
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
                    .scrollTargetLayout()
                }
                .scrollPosition(id: $scrollAnchorID, anchor: .bottom)
                .defaultScrollAnchor(.bottom)
                .onChange(of: scrollRequest) { _, _ in
                    DispatchQueue.main.async {
                        withAnimation(SatoriTheme.Motion.quick) {
                            proxy.scrollTo(responseBottomID, anchor: .bottom)
                        }
                    }
                }
                .onChange(of: response?.text) { _, _ in
                    // 回答是流式增长的；只在回答进行中跟随底部，避免用户
                    // 翻阅历史时被每个 token 抢回最新位置。
                    guard isThinking else { return }
                    DispatchQueue.main.async {
                        proxy.scrollTo(responseBottomID, anchor: .bottom)
                    }
                }
                .onChange(of: turns.count) { _, _ in
                    // 流结束后草稿会归档进 turns，再补一次滚动，确保最后
                    // 一段 Markdown 没有被输入框挡住。
                    DispatchQueue.main.async {
                        proxy.scrollTo(responseBottomID, anchor: .bottom)
                    }
                }
                .overlay(alignment: .bottom) {
                    if !isAtBottom {
                        Button {
                            scrollAnchorID = responseBottomID
                            scrollRequest += 1
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
            }

            if let activeSelectionText, let activeSelectionPage {
                selectionAnchorBanner(text: activeSelectionText, pageIndex: activeSelectionPage)
            }

            if let activeRegionAnchor {
                regionAnchorBanner(activeRegionAnchor)
            }

            if pendingVerification {
                verificationBanner
            }

            if showsPageEntry {
                pageEntryPrompt
            }

            Divider()
            composer
        }
    }

    private func selectionAnchorBanner(text: String, pageIndex: Int) -> some View {
        let isCurrentPage = pageIndex == self.pageIndex
        let pageLabel = readingPageLabel(pageIndex)
        return HStack(alignment: .top, spacing: SatoriTheme.Spacing.sm) {
            Image(systemName: "text.quote")
                .foregroundStyle(SatoriTheme.accent)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(isCurrentPage ? "原文选区 · \(pageLabel)" : "上次卡在\(pageLabel)")
                        .font(.caption.weight(.semibold))
                    Text(isCurrentPage ? "回答会围绕这段内容" : "可返回这段原文")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if isCurrentPage {
                    Text(text.trimmingCharacters(in: .whitespacesAndNewlines))
                        .font(.callout)
                        .lineLimit(3)
                        .foregroundStyle(.primary.opacity(0.82))
                }
                Button(isCurrentPage ? "回到原文" : "返回", systemImage: "arrow.up.right") {
                    returnToSelection(pageIndex: pageIndex, selectionText: text)
                }
                .buttonStyle(.link)
                .font(.caption.weight(.medium))
            }
            Spacer(minLength: 4)
            Button("清除选区锚点", systemImage: "xmark") {
                activeSelectionText = nil
                activeSelectionPage = nil
                activeSelectionOffset = nil
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("隐藏这段原文，但不会删除问答")
        }
        .padding(SatoriTheme.Spacing.md)
        .background(SatoriTheme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: SatoriTheme.Radius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: SatoriTheme.Radius.md, style: .continuous)
                .strokeBorder(SatoriTheme.accent.opacity(0.18), lineWidth: 1)
        )
    }

    /// Keep the optional verification explicit and escapable. Without this
    /// affordance, the next ordinary question would silently be interpreted
    /// as an answer to the generated scenario.
    private var verificationBanner: some View {
        HStack(alignment: .center, spacing: SatoriTheme.Spacing.sm) {
            Image(systemName: "checkmark.circle")
                .foregroundStyle(SatoriTheme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("理解验证")
                    .font(.caption.weight(.semibold))
                Text("想回答情境就点“回答”；也可以直接继续提问。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button("回答") {
                verificationAnswerMode = true
                isQuestionFocused = true
            }
            .buttonStyle(.borderless)
            .font(.caption.weight(.medium))
            .foregroundStyle(SatoriTheme.accent)
            Button("继续提问") {
                pendingVerification = false
                pendingVerificationScope = nil
                verificationAnswerMode = false
                isQuestionFocused = true
            }
            .buttonStyle(.borderless)
            .font(.caption.weight(.medium))
            .foregroundStyle(SatoriTheme.accent)
        }
        .padding(.horizontal, SatoriTheme.Spacing.md)
        .padding(.vertical, SatoriTheme.Spacing.sm)
        .background(SatoriTheme.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: SatoriTheme.Radius.sm, style: .continuous))
        .padding(.horizontal, SatoriTheme.Spacing.md)
        .padding(.bottom, SatoriTheme.Spacing.sm)
    }

    private func regionAnchorBanner(_ anchor: ReadingRegionAnchor) -> some View {
        let isCurrentPage = anchor.pageIndex == pageIndex
        return HStack(alignment: .center, spacing: SatoriTheme.Spacing.sm) {
            Image(systemName: "viewfinder")
                .foregroundStyle(SatoriTheme.gold)
            VStack(alignment: .leading, spacing: 2) {
                Text(isCurrentPage
                     ? "当前框选 · \(readingPageLabel(anchor.pageIndex))"
                     : "上次框选 · \(readingPageLabel(anchor.pageIndex))")
                    .font(.caption.weight(.semibold))
                Text(isCurrentPage
                     ? "后续追问会继续围绕这块区域，不会在整页代码之间猜。"
                     : "回到这一页后，Satori 会恢复这块区域。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if !isCurrentPage {
                Button("返回") {
                    navigateToPage(anchor.pageIndex)
                }
                .buttonStyle(.link)
                .font(.caption.weight(.medium))
                .foregroundStyle(SatoriTheme.accent)
            }
            Button("清除框选锚点", systemImage: "xmark") {
                let regionID = activeRegionAttachment?.id
                activeRegionAnchor = nil
                activeRegionAttachment = nil
                if let regionID {
                    attachments.removeAll { $0.id == regionID }
                }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("清除当前框选；不会删除已经保存的问答")
        }
        .padding(.horizontal, SatoriTheme.Spacing.md)
        .padding(.vertical, SatoriTheme.Spacing.sm)
        .background(SatoriTheme.gold.opacity(0.08), in: RoundedRectangle(cornerRadius: SatoriTheme.Radius.sm, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: SatoriTheme.Radius.sm, style: .continuous)
                .strokeBorder(SatoriTheme.gold.opacity(0.2), lineWidth: 1)
        )
        .padding(.horizontal, SatoriTheme.Spacing.md)
        .padding(.bottom, SatoriTheme.Spacing.sm)
    }

    private func returnToSelection(pageIndex: Int, selectionText: String) {
        navigateToPage(
            pageIndex,
            selectionText: selectionText,
            selectionOffset: activeSelectionOffset
        )
    }

    /// 阅读入口只在打开书、进入新章/习题区，或“上一页刚讲过、当前页还没问过”
    /// 时出现。普通连续翻页保持安静，避免每一页都变成待处理任务。
    private var showsPageEntry: Bool {
        guard !isLoadingHistory,
              !isThinking,
              activeSelectionPage != pageIndex,
              dismissedPageEntryPage != pageIndex else { return false }
        guard !groundedTurns.contains(where: { $0.pageIndex == pageIndex }) else { return false }
        // Chapter/exercise transitions get a route prompt; a normal page only
        // gets a quiet continuation prompt when the immediately previous page
        // was just discussed. This keeps a long reading run calm without
        // leaving a returning reader in front of an unexplained empty panel.
        return pageIndex == 0
            || chapterStartRange != nil
            || exerciseStartRange != nil
            || isContinuationEntry
            || isFrontMatterEntry
    }

    private var isContinuationEntry: Bool {
        guard pageIndex > 0,
              currentPageTurns.isEmpty,
              !groundedTurns.isEmpty else { return false }
        // 只认最近一轮问答，避免用户从“回看”或阅读位置恢复到旧页时，
        // 把几天前的上一页记录误包装成刚刚发生的续读动作。
        guard let latestTurn = groundedTurns.max(by: { $0.createdAt < $1.createdAt }) else { return false }
        return latestTurn.pageIndex == pageIndex - 1
    }

    private var pageEntryPrompt: some View {
        let chapterRange = chapterStartRange
        let exerciseRange = exerciseStartRange
        let isContinuation = isContinuationEntry && chapterRange == nil && exerciseRange == nil
        let isFrontMatter = isFrontMatterEntry
        let pageLabel = readingPageLabel(pageIndex)
        return HStack(alignment: .center, spacing: SatoriTheme.Spacing.sm) {
            Image(systemName: "arrow.down.right.circle")
                .foregroundStyle(SatoriTheme.accent)

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: isFrontMatter
                     ? "现在是正文前的导读"
                     : (isContinuation
                        ? "刚翻到\(pageLabel)"
                        : (exerciseRange == nil ? "刚到\(pageLabel)" : "这里进入习题区")))
                    .font(.caption.weight(.semibold))
                Text(isFrontMatter
                     ? "想快速掌握全书，可以先扫一眼目标，再从第一章开始。"
                     : (isContinuation
                        ? "上一页最近有一轮讨论，先把主线接到这里。"
                        : (exerciseRange == nil
                           ? (chapterRange == nil ? "先抓主线，卡住了再追问。" : "先看本章路线，卡住了再追问。")
                           : "先看题型和起手顺序，卡住了再选一道题。")))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 2)

            if isFrontMatter {
                if let firstTopLevelChapter {
                    Button("从第一章开始", systemImage: "arrow.forward.to.line") {
                        dismissedFrontMatterEntry = true
                        navigateToPage(firstTopLevelChapter.pageIndex)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(SatoriTheme.accent)
                    .help("跳过前言和大纲，从第一章正文开始")
                }

                Button("先讲这一页") {
                    dismissedFrontMatterEntry = true
                    askAssistant(
                        "这一页最重要的一个意思是什么？请用三句话告诉我：我现在先读懂什么、它在解决什么问题、哪些细节可以先放过。只依据当前页。",
                        pageOverride: pageIndex,
                        scope: .page
                    )
                }
                .buttonStyle(.borderless)
                .font(.caption.weight(.medium))
                .foregroundStyle(SatoriTheme.accent)
            } else if isContinuation {
                Button("接上文", systemImage: "arrow.left") {
                    askAssistant(
                        "把上一页和当前页接起来讲：上一页在解决什么，当前页新增了什么，哪些概念要连起来看？控制在 3 个短点以内。",
                        pageOverride: pageIndex,
                        scope: .pageRange(start: pageIndex - 1, end: pageIndex)
                    )
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(SatoriTheme.accent)
                .help("结合上一页和当前页，快速接住主线")

                Button("只讲本页") {
                    askAssistant(
                        "这一页最重要的一个意思是什么？请用三句话告诉我：我现在先读懂什么、它在解决什么问题、哪些细节可以先放过。只依据当前页。",
                        pageOverride: pageIndex,
                        scope: .page
                    )
                }
                .buttonStyle(.borderless)
                .font(.caption.weight(.medium))
                .foregroundStyle(SatoriTheme.accent)
            } else {
                Button(exerciseRange == nil
                       ? (chapterRange == nil ? "先讲主线" : "看本章路线")
                       : "看题型地图", systemImage: "sparkles") {
                    if let exerciseRange {
                        askAssistant(
                            "这里进入了本章的习题区。请先给我一张题型地图：这些题分别在考什么、建议先做哪一类、哪些细节可以第二遍再看。最多 5 点，不要逐题解答，也不要把题目逐条复述。",
                            pageOverride: pageIndex,
                            scope: .pageRange(start: exerciseRange.lowerBound, end: exerciseRange.upperBound),
                            readingMap: true
                        )
                    } else if let chapterRange {
                        askAssistant(
                            "我刚开始读这一章。请先给我一张阅读路线图：这章要解决哪几个问题、概念怎样递进、哪些是主干、哪些细节可以第二遍再看。控制在 5 点以内，依据本章内容，不要逐页复述。",
                            pageOverride: pageIndex,
                            scope: .pageRange(start: chapterRange.lowerBound, end: chapterRange.upperBound),
                            readingMap: true
                        )
                    } else {
                        askAssistant(
                            "这一页最重要的一个意思是什么？请用三句话告诉我：我现在先读懂什么、它在解决什么问题、哪些细节可以先放过。只依据当前页，不要猜测未提供的前文。",
                            pageOverride: pageIndex,
                            scope: .page
                        )
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(SatoriTheme.accent)
                .help(exerciseRange == nil
                      ? (chapterRange == nil ? "先抓住当前页的主线" : "先了解这一章的结构和阅读顺序")
                      : "先了解习题的题型和起手顺序")

                if pageIndex > 0 {
                    Button("接上文", systemImage: "arrow.left") {
                        askAssistant(
                            "把这一页和前一页接起来讲：前一页在解决什么，这一页新增了什么，哪些概念要连起来看？请用容易理解的话说明。",
                            pageOverride: pageIndex,
                            scope: .pageRange(start: pageIndex - 1, end: pageIndex)
                        )
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("同时参考前一页和当前页")
                }
            }

            Button("收起", systemImage: "xmark") {
                if isFrontMatter {
                    dismissedFrontMatterEntry = true
                }
                dismissedPageEntryPage = pageIndex
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("收起本页入口")
        }
        .padding(.horizontal, SatoriTheme.Spacing.md)
        .padding(.vertical, SatoriTheme.Spacing.sm)
        .background(SatoriTheme.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: SatoriTheme.Radius.sm, style: .continuous))
        .padding(.horizontal, SatoriTheme.Spacing.md)
        .padding(.bottom, SatoriTheme.Spacing.sm)
    }

    private func selectionScope(for intent: ReaderSelectionIntent, pageIndex: Int) -> LearningContextScope {
        guard intent == .context, pageIndex > 0 else { return .page }
        return .pageRange(start: pageIndex - 1, end: pageIndex)
    }

    private func selectionPrompt(for intent: ReaderSelectionIntent, pageIndex: Int) -> String {
        let instruction: String
        switch intent {
        case .explain:
            instruction = "请用更容易理解的话解释下面这段原文，并指出它在当前页中的关键意思。"
        case .context:
            instruction = pageIndex > 0
                ? "请结合前一页和当前页，说明下面这段原文为什么出现在这里：前一页在解决什么、当前页新增了什么，以及两页之间最重要的连接是什么。"
                : "请说明下面这段原文为什么出现在当前页，以及它在这一页中承接和引出的内容。"
        case .example:
            instruction = "请给下面这段原文举一个具体、贴近日常或实际工作的例子，帮助我建立直觉。"
        case .experiment:
            instruction = "请简要设计一个 30 秒内能完成的微实验，按“目的—操作—观察—对应概念”给出，最多 5 步。若需要代码，只给纯计算的 Python、C 或 C++ 小片段，不访问文件、不联网、不启动系统命令；不要给 Shell 命令。若不适合代码实验，就给纸笔、想象或生活中的可观察替代实验。如果不适合实验，先说明原因，再给替代例子。不要长篇复述原文。"
        }
        return instruction
    }

    /// 章节首页是读者最需要地图的地方；只对一级目录项生效，避免子节开头
    /// 误触发整章提取。范围沿用目录边界，因此不会把下一章混进路线图。
    private var chapterStartRange: ClosedRange<Int>? {
        guard let chapter = currentTopLevelChapter,
              chapter.pageIndex == pageIndex else { return nil }
        return BookChapter.pageRange(for: chapter, in: chapters, pageCount: pageCount)
    }

    /// An outline-marked exercise section is a useful transition point for a
    /// student, but only show the entry on its first page. If the PDF has no
    /// such outline node, normal page reading remains completely quiet.
    private var exerciseStartRange: ClosedRange<Int>? {
        guard let chapter = currentChapter,
              chapter.pageIndex == pageIndex,
              ReadingPagePurpose.isExerciseHeading(chapter.title) else { return nil }
        return BookChapter.pageRange(for: chapter, in: chapters, pageCount: pageCount)
    }

    /// 不把阅读变成考试：只在用户主动选择时给一个小情境，先让他用自己的话
    /// 作答，再沿着最近对话判断理解是否成立并指出最关键的修正。
    private var verificationPrompt: String {
        "请做一次轻量理解验证。不要复述答案，也不要直接给结论；只给我一个和刚才内容相关的具体小情境或问题，让我先用自己的话回答。等我下一条消息后，再判断我的理解是否正确，并指出最关键的一处修正。控制在两三句话。"
    }

    /// 回答完成时用户已经翻页：提示它存进了哪一页，不再"答完就消失"。
    private func savedElsewhereBanner(pageIndex: Int) -> some View {
        HStack(spacing: SatoriTheme.Spacing.sm) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 15))
                .foregroundStyle(SatoriTheme.accent)
            Text("回答已留在\(readingPageLabel(pageIndex))")
                .font(.callout.weight(.medium))
            Spacer()
            Button("去看看") {
                navigateToPage(pageIndex)
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
                        Text("问答记录加载失败")
                            .font(.callout.weight(.medium))
                        Text(historyStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, SatoriTheme.Spacing.xxl)
                } else if groundedTurns.isEmpty {
                    VStack(spacing: SatoriTheme.Spacing.sm) {
                        Image(systemName: "book.pages")
                            .font(.system(size: 32))
                            .foregroundStyle(.tertiary)
                        Text(staleHistoryCount > 0 ? "没有可用的问答记录" : "还没有问答记录")
                            .font(.callout.weight(.medium))
                        Text(staleHistoryCount > 0
                             ? "旧记录的页码范围与所在页对不上，已暂时隐藏；它们没有被删除，也不会影响新的回答。"
                             : "去「问」里和 AI 讨论这一页，问答会自动按页留在这里。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, SatoriTheme.Spacing.xxl)
                } else {
                    if staleHistoryCount > 0 {
                        staleHistoryNotice
                    }
                    ForEach(pageSections) { section in
                        pageSectionView(section)
                    }
                }
            }
            .padding(SatoriTheme.Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var runRequiresStandardInput: Bool {
        CodeRunner.requiresStandardInput(for: runCode, language: runLanguage)
    }

    private var runSafety: ExperimentSafety {
        CodeRunner.safety(
            for: runCode,
            language: runLanguage,
            allowsStandardInput: runRequiresStandardInput
        )
    }

    private var canRunSnippet: Bool {
        guard !runCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              runSafety.isAllowed else { return false }
        return !runRequiresStandardInput
            || !runStandardInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 运行 — a quick scratchpad to execute code locally. Paste from the PDF
    /// selection (or anywhere), optionally provide one fixed input, hit run,
    /// and see output.
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

                        Picker("实验语言", selection: $runLanguage) {
                            ForEach(CodeRunner.experimentLanguages, id: \.self) { lang in
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
                        .disabled(!canRunSnippet && !isRunning)
                    }

                    if !runNotice.isEmpty {
                        Label(runNotice, systemImage: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let runSourcePage {
                        Label("来自\(readingPageLabel(runSourcePage))的选区；请先检查代码，再运行", systemImage: "text.quote")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    ZStack(alignment: .topLeading) {
                        if runCode.isEmpty {
                            Text("先从 PDF 选中一段完整的纯计算代码，或把代码粘贴到这里…")
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

                    if runRequiresStandardInput {
                        HStack(spacing: SatoriTheme.Spacing.sm) {
                            Label("固定输入", systemImage: "keyboard")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                            TextField("例如：3 4", text: $runStandardInput)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.caption, design: .monospaced))
                                .disabled(isRunning)
                            Text("只送入这一组输入，然后关闭")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }

                    if !runCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       let safetyMessage = runSafety.message {
                        Label(safetyMessage, systemImage: "lock.slash")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

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
        guard canRunSnippet, !isRunning else { return }
        isRunning = true
        runOutput = nil
        let language = runLanguage
        let input = runRequiresStandardInput ? runStandardInput : nil
        runTask = Task {
            let result = await CodeRunner.run(code: code, language: language, standardInput: input)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                runOutput = result
                isRunning = false
            }
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
        let grouped = Dictionary(grouping: groundedTurns, by: \.pageIndex)
        // 当前阅读页优先，其余页面按最近讨论排序。读者从当前页进入「回看」
        // 时应该先看到眼前这页，而不是被别处最近的一轮问答带走。
        return grouped.keys.sorted { lhs, rhs in
            let lhsIsCurrent = lhs == pageIndex
            let rhsIsCurrent = rhs == pageIndex
            if lhsIsCurrent != rhsIsCurrent { return lhsIsCurrent }
            let lastA = grouped[lhs]?.last?.createdAt ?? .distantPast
            let lastB = grouped[rhs]?.last?.createdAt ?? .distantPast
            if lastA != lastB { return lastA > lastB }
            return lhs > rhs
        }.map { PageSection(pageIndex: $0, turns: grouped[$0] ?? []) }
    }

    private var currentPageTurns: [LearningTurn] {
        groundedTurns.filter { $0.pageIndex == pageIndex }
    }

    private var groundedTurns: [LearningTurn] {
        turns.filter(ReadingConversationContextSelector.hasConsistentAnchor)
    }

    /// The first top-level recovered chapter is also a useful boundary between
    /// book front matter and the content a fast reader actually came for.
    /// Native-outline books and scanned books share this path, while books
    /// without a recovered chapter simply keep the normal page entry.
    private var firstTopLevelChapter: BookChapter? {
        let index = ReadingChapterSelector.firstRealChapterIndex(
            titles: chapters.map(\.title),
            depths: chapters.map(\.depth)
        )
        return index.flatMap { chapters.indices.contains($0) ? chapters[$0] : nil }
    }

    private var isFrontMatterEntry: Bool {
        guard !dismissedFrontMatterEntry,
              currentPageTurns.isEmpty,
              let firstTopLevelChapter,
              pageIndex < firstTopLevelChapter.pageIndex else { return false }
        return true
    }

    private var staleHistoryCount: Int {
        max(0, turns.count - groundedTurns.count)
    }

    private var staleHistoryNotice: some View {
        Label(
            "\(staleHistoryCount) 条旧问答的页码范围与所在页不一致，已暂时隐藏；它们没有被删除，也不会影响新的回答。",
            systemImage: "clock.arrow.circlepath"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(SatoriTheme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: SatoriTheme.Radius.sm, style: .continuous))
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
                    // 输入框里手打的问题走智能范围；没有章节/跨页意图时回到当前页。
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

    /// 翻到一个没有历史问答的页面时，保持阅读现场有反馈，但不把每次翻页
    /// 都变成一组待处理按钮。章节入口和“接上文”仍由 pageEntryPrompt 负责。
    private var emptyPageHint: some View {
        HStack(alignment: .top, spacing: SatoriTheme.Spacing.sm) {
            Image(systemName: "book.pages")
                .foregroundStyle(SatoriTheme.accent)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 3) {
                Text("这一页还没有问答")
                    .font(.callout.weight(.semibold))
                Text("先读正文；卡住时选中一段，或直接在下方问一句。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, SatoriTheme.Spacing.sm)
        .foregroundStyle(.secondary)
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
                previews: isActive ? activeAttachmentPreviews : [],
                selectionText: turn.selectionText,
                selectionOffset: turn.selectionAnchorOffset
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
        previews: [NSImage],
        selectionText: String?,
        selectionOffset: Double?
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
                            Button(label) {
                                navigateToPage(
                                    pageIndex,
                                    selectionText: selectionText,
                                    selectionOffset: selectionOffset
                                )
                            }
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

    private func readingPageLabel(_ index: Int) -> String {
        let pdfLabel = "第 \(index + 1) 页"
        guard let printedPage = printedPageForPage(index) else { return pdfLabel }
        return "\(pdfLabel) · 书内 \(printedPage)"
    }

    /// 气泡里展示「这一轮问答依据什么」；nil 视为旧版本数据（按「当前页」理解）。
    private func contextAnchorLabel(_ scope: LearningContextScope?, pageIndex: Int) -> String? {
        switch scope {
        case .some(.none):
            // 不带上下文：不显示页码锚点，避免误导。
            return nil
        case .some(.page), nil:
            return readingPageLabel(pageIndex)
        case let .some(.pageRange(start, end)):
            let pdfLabel = start == end ? "第 \(start + 1) 页" : "第 \(start + 1)–\(end + 1) 页"
            let printedLabel: String? = {
                guard let printedStart = printedPageForPage(start) else { return nil }
                guard start != end else { return "书内 \(printedStart)" }
                guard let printedEnd = printedPageForPage(end) else { return nil }
                return "书内 \(printedStart)–\(printedEnd)"
            }()
            let rangeLabel = printedLabel.map { "\(pdfLabel) · \($0)" } ?? pdfLabel
            if let chapter = chapters.first(where: { chapter in
                guard chapter.depth == 0,
                      let chapterRange = BookChapter.pageRange(for: chapter, in: chapters, pageCount: pageCount)
                else { return false }
                return chapterRange.lowerBound == start && chapterRange.upperBound == end
            }) {
                return "\(chapter.title) · \(rangeLabel)"
            }
            return rangeLabel
        case .some(.wholeDocument):
            return "整本书"
        }
    }

    /// 阅读页脚里的一枚小标签：只保留能帮助读者判断依据的事实。
    private struct ProcessChip: Equatable {
        let symbol: String
        let text: String
    }

    /// 回答卡片底部的处理过程：上下文、附图、联网搜索来源。
    /// 模型名和耗时属于调试信息，不应占据默认阅读空间。
    private func processChips(turn: LearningTurn, isActive: Bool) -> [ProcessChip] {
        var chips: [ProcessChip] = []
        if let label = contextAnchorLabel(turn.contextScope, pageIndex: turn.pageIndex) {
            chips.append(.init(symbol: "book", text: label))
        }
        if turn.attachmentCount > 0 {
            chips.append(.init(symbol: "paperclip", text: "附图 \(turn.attachmentCount) 张"))
        }
        if isActive, requestUsesWebSearch {
            chips.append(.init(symbol: "globe", text: "正在联网搜索…"))
        } else if !turn.citations.isEmpty {
            chips.append(.init(symbol: "globe", text: "联网搜索 · \(turn.citations.count) 个来源"))
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
                completion: turn.completion,
                pageIndex: turn.pageIndex
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
                if let attachmentNotice = turn.attachmentNotice,
                   !attachmentNotice.isEmpty {
                    Label(attachmentNotice, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                            scope: turn.contextScope ?? .page,
                            selectionText: turn.selectionText,
                            selectionOffset: turn.selectionAnchorOffset
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
        let pageLabel = readingPageLabel(section.pageIndex)
        return VStack(alignment: .leading, spacing: SatoriTheme.Spacing.sm) {
            Button {
                navigateToPage(section.pageIndex)
            } label: {
                HStack(spacing: SatoriTheme.Spacing.sm) {
                    Text(pageLabel)
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
            .help("跳到\(pageLabel)")

            ForEach(section.turns) { turn in
                conversationTurnCard(turn)
                    .id(turn.id)
            }
        }
    }

    private func answerHeader(
        sourceKind: LearningSourceKind,
        isStreaming: Bool,
        completion: LearningTurnCompletion,
        pageIndex: Int
    ) -> some View {
        let pageLabel = readingPageLabel(pageIndex)
        return HStack {
            Label(
                isStreaming ? "Qwen 正在回答\(pageLabel)" : sourceKind.localizedTitle,
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
                // 从「回看」重试时先回到问答现场，否则请求虽然会发出，
                // 用户却留在历史列表里看不到流式回答，也不知道是否成功。
                selectMode(.ask)
                navigateToPage(
                    turn.pageIndex,
                    selectionText: turn.selectionText,
                    selectionOffset: turn.selectionAnchorOffset
                )
                askAssistant(
                    turn.question,
                    pageOverride: turn.pageIndex,
                    excludingTurnID: turn.id,
                    scope: turn.contextScope ?? .page,
                    selectionText: turn.selectionText,
                    selectionOffset: turn.selectionAnchorOffset
                )
            }
            .buttonStyle(.borderless)
            Menu {
                if turn.pageIndex < pageCount - 1 {
                    Button("继续到下一页", systemImage: "arrow.right") {
                        continueToNextPage(from: turn)
                    }
                    Divider()
                }
                Button("验证一下", systemImage: "checkmark.circle") {
                    selectMode(.ask)
                    navigateToPage(
                        turn.pageIndex,
                        selectionText: turn.selectionText,
                        selectionOffset: turn.selectionAnchorOffset
                    )
                    askAssistant(
                        verificationPrompt,
                        pageOverride: turn.pageIndex,
                        scope: turn.contextScope ?? .page,
                        selectionText: turn.selectionText,
                        selectionOffset: turn.selectionAnchorOffset,
                        verification: true
                    )
                }
                Button("压缩成短版", systemImage: "text.badge.minus") {
                    selectMode(.ask)
                    navigateToPage(
                        turn.pageIndex,
                        selectionText: turn.selectionText,
                        selectionOffset: turn.selectionAnchorOffset
                    )
                    askAssistant(
                        "把你刚才的回答压缩成一眼能读的短版：最多 3 个短点，只保留核心结论和必要的一个连接，不要新增内容、不要重复大段原文。",
                        pageOverride: turn.pageIndex,
                        scope: turn.contextScope ?? .page,
                        selectionText: turn.selectionText,
                        selectionOffset: turn.selectionAnchorOffset
                    )
                }
                Divider()
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

    /// A completed answer is a natural handoff point in a textbook. Keep the
    /// action in the overflow menu so the reading surface stays quiet, but let
    /// a student move to the next page and ask for the smallest useful bridge
    /// without retyping “接上文”.
    private func continueToNextPage(from turn: LearningTurn) {
        let nextPage = min(pageCount - 1, turn.pageIndex + 1)
        guard nextPage > turn.pageIndex else { return }
        selectMode(.ask)
        navigateToPage(nextPage)
        askAssistant(
            "继续",
            pageOverride: nextPage,
            scope: .pageRange(start: turn.pageIndex, end: nextPage)
        )
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: SatoriTheme.Spacing.sm) {
            if !attachments.isEmpty { attachmentStrip }

            contextScopeRow

            ZStack(alignment: .topLeading) {
                if question.isEmpty {
                    Text(composerPlaceholder)
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

    /// 提问参考上下文选择：默认按问题智能选择，需要时仍可明确指定范围。
    private var contextScopeRow: some View {
        HStack(spacing: SatoriTheme.Spacing.sm) {
            Menu {
                Picker("参考上下文", selection: contextModeBinding) {
                    Label("智能范围", systemImage: "wand.and.stars").tag(ContextMode.automatic)
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
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .menuStyle(.borderlessButton)
            .font(.caption)
            .foregroundStyle(.secondary)
            .help("提问时给 AI 的参考内容。默认按问题自动选择，普通问题使用当前页。")

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
            let pdfLabel = "PDF \(range.lowerBound + 1)–\(range.upperBound + 1)"
            guard let printedStart = printedPageForPage(range.lowerBound),
                  let printedEnd = printedPageForPage(range.upperBound) else {
                return pdfLabel
            }
            return "\(pdfLabel) · 书内 \(printedStart)–\(printedEnd)"
        }
        if let printedPage = printedPageForPage(chapter.pageIndex) {
            return "PDF \(chapter.pageIndex + 1) · 书内 \(printedPage)"
        }
        return "PDF \(chapter.pageIndex + 1)"
    }

    /// 当前页所属的章节（最后一个起始页 ≤ 当前页）。
    private var currentChapter: BookChapter? {
        chapters.last { $0.pageIndex <= pageIndex }
    }

    /// 实际使用的上下文节点：用户主动选中的章/节优先；没有主动选择时，
    /// “章节”默认跟随当前顶层章，而不是当前页恰好落入的最后一个小节。
    private var activeChapter: BookChapter? {
        if let selectedChapterID, let chapter = chapters.first(where: { $0.id == selectedChapterID }) {
            return chapter
        }
        return currentTopLevelChapter
    }

    private func topLevelChapter(for chapter: BookChapter) -> BookChapter? {
        chapters.last { $0.depth == 0 && $0.pageIndex <= chapter.pageIndex }
    }

    /// 切到「多页」时默认从当前页开始，再往前后扩展。
    private var contextModeBinding: Binding<ContextMode> {
        Binding(
            get: { contextMode },
            set: { newMode in
                if newMode == .automatic || newMode == .chapter {
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

    /// 让自然语言决定默认取材范围，避免用户先学会配置菜单才能问
    /// “这一章在讲什么”。只在「智能范围」下启用；用户明确选择范围后
    /// 尊重选择，不暗中扩大请求。
    private func inferredContextScope(for request: String, pageIndex: Int) -> LearningContextScope? {
        let chapterRange = chapterForInference(for: request).flatMap {
            BookChapter.pageRange(for: $0, in: chapters, pageCount: pageCount)
        }
        let sectionRange = activeChapter.flatMap {
            BookChapter.pageRange(for: $0, in: chapters, pageCount: pageCount)
        }
        if let explicit = ReadingScopeInference.scope(
            for: request,
            pageIndex: pageIndex,
            chapterRange: chapterRange,
            sectionRange: sectionRange,
            pageCount: pageCount
        ) {
            return explicit
        }

        // A student naturally follows “这一章在说什么” with “有多少页” or
        // “有什么值得看”. Keep terse follow-ups attached to the last
        // meaningful range; otherwise the thread abruptly collapses to one
        // current page and loses the chapter map.
        guard ReadingScopeInference.inheritsRecentScope(for: request) else { return nil }
        return groundedTurns.reversed().compactMap { turn -> LearningContextScope? in
            guard let scope = turn.contextScope,
                  ReadingScopeInference.isRecentScopeRelevant(
                      scope,
                      turnPageIndex: turn.pageIndex,
                      currentPageIndex: pageIndex
                  ) else { return nil }
            return scope
        }.first
    }

    /// “这一章”跟随当前阅读位置；“第六章”则优先匹配目录中的明确章节，
    /// 匹配不到时不猜另一章，交给调用方回到当前页范围。
    private func chapterForInference(for request: String) -> BookChapter? {
        let normalized = request
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let numberedChapterRange = normalized.range(
            of: #"第[0-9一二三四五六七八九十百]+章"#,
            options: .regularExpression
        )
        if let numberedChapterRange {
            let marker = String(normalized[numberedChapterRange])
            if let requestedNumber = ChapterNumberParser.number(in: marker) {
                return chapters.first {
                    $0.depth == 0 && ChapterNumberParser.number(in: $0.title) == requestedNumber
                }
            }
            return chapters.first { $0.depth == 0 && $0.title.lowercased().contains(marker) }
        }
        return currentTopLevelChapter
    }

    private var contextModePickerTitle: String {
        switch contextMode {
        case .automatic: "智能范围"
        case .none: "不带上下文"
        case .page: "当前页"
        case .chapter:
            if let activeChapter,
               BookChapter.pageRange(for: activeChapter, in: chapters, pageCount: pageCount) != nil {
                "章节 · \(activeChapter.title)（\(chapterPageRangeLabel(activeChapter))）"
            } else {
                "章节"
            }
        case .pageRange:
            contextAnchorLabel(
                .pageRange(start: rangeStart - 1, end: rangeEnd - 1),
                pageIndex: pageIndex
            ) ?? (rangeStart == rangeEnd ? "PDF \(rangeStart)" : "PDF \(rangeStart)–\(rangeEnd)")
        case .wholeDocument: "整本书"
        }
    }

    private var contextModeSystemImage: String {
        switch contextMode {
        case .automatic: "wand.and.stars"
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

    private var composerPlaceholder: String {
        if pendingVerification && verificationAnswerMode {
            return "用自己的话回答上面的情境…"
        }
        if groundedTurns.isEmpty {
            return "想问什么？可以附上图片…"
        }
        if currentPageTurns.isEmpty {
            return "从这一页开始问：它在讲什么、为什么、怎么用…"
        }
        return "继续追问这里为什么、再举个例子…"
    }

    private var composerHint: String {
        let web = allowsWebSearch ? "、联网" : ""
        if pendingVerification, verificationAnswerMode, !isThinking {
            let scopeText = contextAnchorLabel(
                pendingVerificationScope ?? .page,
                pageIndex: pageIndex
            ) ?? readingPageLabel(pageIndex)
            return "先用自己的话回答上面的情境 · Enter 发送 · Shift+Enter 换行 · 参考：\(scopeText)、最近对话、附件\(web)"
        }
        if pendingVerification, !isThinking {
            return "可以直接继续提问；想回答情境请点上方“回答” · Enter 发送 · Shift+Enter 换行 · 参考：最近对话、附件\(web)"
        }
        let scopeText: String
        if isThinking, !draftQuestion.isEmpty {
            scopeText = contextAnchorLabel(draftContextScope, pageIndex: draftPageIndex) ?? "不带上下文"
        } else {
            switch contextMode {
            case .automatic: scopeText = "按问题自动选择"
            case .none: scopeText = "不带上下文"
            case .page: scopeText = readingPageLabel(pageIndex)
            case .chapter:
                scopeText = activeChapter?.title ?? "章节"
            case .pageRange:
                scopeText = contextAnchorLabel(
                    .pageRange(start: rangeStart - 1, end: rangeEnd - 1),
                    pageIndex: pageIndex
                ) ?? "第 \(rangeStart)–\(rangeEnd) 页"
            case .wholeDocument: scopeText = "整本书"
            }
        }
        let prefix = isThinking && !draftQuestion.isEmpty ? "本轮参考" : "参考"
        return "Enter 发送 · Shift+Enter 换行 · ⌘V 贴图 · \(prefix)：\(scopeText)、最近对话、附件\(web)"
    }

    private var streamingStatusText: String {
        if requestPhase == .loadingConfiguration {
            return "正在连接本机 Qwen 配置…"
        }
        if requestPhase == .preparing {
            return preparingStatusText
        }
        if requestPhase == .waitingForFirstToken {
            return requestUsesWebSearch
                ? "已送达 Qwen，正在联网并等待首段回答…"
                : "已送达 Qwen，等待首段回答…"
        }
        if requestUsesWebSearch { return "正在联网搜索资料并组织回答…" }
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

    private var preparingStatusText: String {
        switch draftContextScope {
        case .none: "正在准备问题…"
        case .page: "正在读取\(readingPageLabel(draftPageIndex))…"
        case .pageRange: "正在整理所选页面…"
        case .wholeDocument: "正在整理全书内容…"
        }
    }

    @MainActor
    private func loadHistory() async {
        isLoadingHistory = true
        historyStatus = ""
        turns = []
        activeSelectionText = nil
        activeSelectionPage = nil
        activeSelectionOffset = nil
        activeRegionAnchor = nil
        activeRegionAttachment = nil
        completedElsewherePage = nil
        recentCompletedPage = nil
        pendingVerification = false
        pendingVerificationScope = nil
        verificationAnswerMode = false
        draftIsVerification = false
        requestPhase = .preparing
        do {
            let loadedTurns = try await sessionStore.turns(for: documentID)
            guard !Task.isCancelled else { return }
            turns = loadedTurns
            // 如果上次离开这本书时正围绕某段原文提问，恢复最近的选区。
            // 跨页也只显示成一行低干扰的「上次卡在第 N 页」，不抢当前页
            // 的阅读入口，但让用户能一键回到真正卡住的位置。
            if let restoredSelection = groundedTurns.reversed().first(where: {
                $0.selectionText?.isEmpty == false
            }) {
                activeSelectionText = restoredSelection.selectionText
                activeSelectionPage = restoredSelection.pageIndex
                activeSelectionOffset = restoredSelection.selectionAnchorOffset
            }
            if let restoredRegion = groundedTurns.reversed().compactMap(\.regionAnchor).first {
                activeRegionAnchor = restoredRegion
                Task {
                    await restoreRegionAttachment(for: restoredRegion)
                }
            }
            dismissedPageEntryPage = nil
            // 打开面板默认看最新对话：锚定到底部，历史加载完自动贴底。
            scrollAnchorID = responseBottomID
            scrollRequest += 1
        } catch {
            guard !Task.isCancelled else { return }
            turns = []
            historyStatus = "问答记录暂时无法读取；不影响继续阅读和提问。"
        }
        isLoadingHistory = false
    }

    private func restoreRegionAttachment(for anchor: ReadingRegionAnchor) async {
        let data = await Task.detached(priority: .utility) {
            PDFRegionRenderer.renderJPEG(from: documentURL, anchor: anchor)
        }.value
        guard !Task.isCancelled,
              activeRegionAnchor == anchor,
              let data,
              let preview = NSImage(data: data) else { return }
        activeRegionAttachment = LearningImageAttachment(
            name: "\(readingPageLabel(anchor.pageIndex)) · 框选",
            jpegData: data,
            preview: preview
        )
    }

    /// 从历史问答回到原文时，恢复选区锚点；没有选区的普通页问答仍只跳到页码。
    private func navigateToPage(
        _ targetPageIndex: Int,
        selectionText: String? = nil,
        selectionOffset: Double? = nil
    ) {
        let trimmedSelection: String?
        if let selectionText {
            let trimmed = selectionText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                activeSelectionText = trimmed
                activeSelectionPage = targetPageIndex
                activeSelectionOffset = selectionOffset
                trimmedSelection = trimmed
            } else {
                trimmedSelection = nil
            }
        } else {
            // A generic history/page jump is not a request to keep explaining
            // the previous passage. Remove the old visual anchor so the panel
            // cannot claim that an unrelated page is still the active hurdle.
            activeSelectionText = nil
            activeSelectionPage = nil
            activeSelectionOffset = nil
            trimmedSelection = nil
        }
        onNavigateToPage(targetPageIndex)

        // 历史气泡里的页码和“返回原文”都走同一条回跳链路：先切到目标页，
        // 再由 PDFReaderView 恢复真正的 PDFSelection。旧存档没有精确选区
        // 偏移时仍能找到原文，只是不拿旧的视口偏移去误选重复短语。
        guard let trimmedSelection else { return }
        let position = ReadingPosition(
            pageIndex: targetPageIndex,
            normalizedPageOffset: selectionOffset ?? 0
        )
        NotificationCenter.default.post(
            name: .satoriReaderJumpRequested,
            object: nil,
            userInfo: [
                "documentID": documentID,
                "url": documentURL,
                "position": position,
                "selectionText": trimmedSelection,
                "selectionOffsetIsExact": selectionOffset != nil
            ]
        )
    }

    private func askAssistant(
        _ suppliedQuestion: String? = nil,
        pageOverride: Int? = nil,
        excludingTurnID: UUID? = nil,
        scope: LearningContextScope = .page,
        selectionText: String? = nil,
        selectionOffset: Double? = nil,
        verification: Bool = false,
        readingMap: Bool = false
    ) {
        let request = (suppliedQuestion ?? question).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty, !isThinking else { return }

        if suppliedQuestion == nil, !verification, requestNeedsChapterMetadata(request) {
            if isLoadingChapters {
                pendingChapterMetadataQuestion = request
                attachmentStatus = "正在识别目录；完成后会按整章范围自动回答。"
                return
            }
            guard canResolveChapterScope(for: request) else {
                attachmentStatus = "没有识别出这章的页码范围；请在“智能范围”里选择多页后再发送。"
                return
            }
        }

        if suppliedQuestion == nil, !verification, routeRunIntentIfPossible(for: request) {
            return
        }

        if suppliedQuestion == nil, !verification, !pendingVerification, CodeRunner.isRunIntent(request) {
            selectMode(.run)
            runCode = ""
            runSourcePage = nil
            runOutput = nil
            runNotice = activeRegionAnchor?.pageIndex == pageIndex
                ? "当前是图片框选；请先让 AI 整理并核对代码，再从回答里的代码卡片运行。Satori 不会从整页 OCR 猜代码。"
                : "先在 PDF 中选中一段完整代码；扫描页可以先用“框选理解”。Satori 不会从整页 OCR 猜代码。"
            question = ""
            return
        }

        // Only a deliberate send after explicitly entering answer mode answers
        // the verification prompt. Ordinary composer questions, selection
        // actions, and quick prompts are new reading actions.
        let isAnswerToVerification = pendingVerification
            && verificationAnswerMode
            && !verification
            && suppliedQuestion == nil
        let verificationAnswerScope = pendingVerificationScope
        let usesWebSearch = allowsWebSearch
            || (!verification && QwenLearningAssistant.shouldAutoEnableWebSearch(for: request))
        pendingVerification = false
        pendingVerificationScope = nil
        verificationAnswerMode = false
        draftIsVerification = verification

        // 输入框发送（suppliedQuestion == nil）优先沿用选区所在页；
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

        // 输入框发送跟着选择器走（默认智能范围）；快捷提问、重问各自带上下文。
        var effectiveScope: LearningContextScope
        if isAnswerToVerification {
            effectiveScope = verificationAnswerScope ?? .page
        } else if suppliedQuestion == nil {
            switch contextMode {
            case .automatic:
                effectiveScope = inferredContextScope(for: request, pageIndex: targetPageIndex) ?? .page
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

        // A student asking for the “完整代码/公式” is usually looking at a
        // page break, not asking for a single-page OCR transcription. Pull in
        // only the adjacent pages when the reader has left scope selection on
        // intelligent mode. Explicit “无上下文/指定范围” choices still win.
        if contextMode == .automatic,
           QwenLearningAssistant.isFullReconstructionRequest(for: request),
           let adjacentRange = ReadingScopeInference.adjacentPageRange(
               around: targetPageIndex,
               pageCount: pageCount
           ) {
            effectiveScope = .pageRange(start: adjacentRange.lowerBound, end: adjacentRange.upperBound)
        }

        // Old archived turns may carry a range produced before chapter
        // boundaries were corrected (for example, a sixth-chapter answer
        // anchored to the end of chapter five). A retry must not blindly
        // resurrect that scope: re-infer from the current outline when the
        // saved range no longer contains the answer's target page, then fall
        // back to the target page if the wording gives us no safer range.
        if excludingTurnID != nil,
           effectiveScope != .none,
           !ReadingScopeInference.isRecentScopeRelevant(
               effectiveScope,
               turnPageIndex: targetPageIndex,
               currentPageIndex: targetPageIndex
           ) {
            effectiveScope = inferredContextScope(for: request, pageIndex: targetPageIndex) ?? .page
        }

        let regionForRequest = activeRegionAnchor?.pageIndex == targetPageIndex
            ? activeRegionAnchor
            : nil
        var submittedAttachments = attachments
        if regionForRequest != nil,
           let activeRegionAttachment,
           !submittedAttachments.contains(where: { $0.id == activeRegionAttachment.id }) {
            // A follow-up such as “完整代码” may arrive after the first crop
            // was sent and removed from the composer. Reattach the same crop
            // before any new user images so the region marker stays truthful.
            submittedAttachments.insert(activeRegionAttachment, at: 0)
        }
        let requestRegionAnchor: ReadingRegionAnchor? = {
            guard let regionForRequest,
                  let activeRegionAttachment,
                  submittedAttachments.contains(where: { $0.id == activeRegionAttachment.id }) else {
                return nil
            }
            return regionForRequest
        }()
        submittedAttachmentsForActiveRequest = submittedAttachments
        activeAttachmentPreviews = submittedAttachments.map(\.preview)
        let context = ReadingConversationContextSelector.select(
            turns: turns,
            targetPageIndex: targetPageIndex,
            scope: effectiveScope,
            excludingTurnID: excludingTurnID
        )
            .map {
                LearningConversationContext(
                    question: $0.question,
                    answer: $0.answer,
                    pageIndex: $0.contextScope == .none ? nil : $0.pageIndex,
                    selectionText: $0.selectionText,
                    attachmentSummary: $0.attachmentCount > 0 ? "\($0.attachmentCount) 张附图" : nil
                )
            }

        draftQuestion = request
        draftPageIndex = targetPageIndex
        draftPageRevision = readingPositionRevision
        draftContextScope = effectiveScope
        draftAttachmentCount = submittedAttachments.count
        draftRegionAnchor = requestRegionAnchor
        let effectiveSelectionText: String? = {
            guard let candidate = (selectionText ?? (activeSelectionPage == targetPageIndex ? activeSelectionText : nil))?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !candidate.isEmpty else { return nil }
            return candidate
        }()
        draftSelectionText = effectiveSelectionText
        let activeSelectionMatches = activeSelectionPage == targetPageIndex
            && activeSelectionText?.trimmingCharacters(in: .whitespacesAndNewlines) == effectiveSelectionText
        let effectiveSelectionOffset: Double? = {
            guard effectiveSelectionText != nil else { return nil }
            return selectionOffset ?? (activeSelectionMatches ? activeSelectionOffset : nil)
        }()
        draftSelectionOffset = effectiveSelectionOffset
        if let effectiveSelectionText, !effectiveSelectionText.isEmpty {
            // 由「回看」里的「重试」重新进入选区问答时，恢复可见锚点，
            // 让用户知道这次回答仍然围绕哪段原文，而不是只在请求里隐形带上它。
            activeSelectionText = effectiveSelectionText
            activeSelectionPage = targetPageIndex
            activeSelectionOffset = effectiveSelectionOffset
        }
        // 锚定到底部：新消息出现后内容自然向上生长，平滑贴底跟随。
        scrollAnchorID = responseBottomID
        scrollRequest += 1
        question = ""
        attachments = []
        attachmentStatus = ""
        response = LearningResponse(text: "", sourceKind: .currentPDF, pageIndex: targetPageIndex)
        isThinking = true
        streamStartDate = .now
        requestPhase = .loadingConfiguration
        requestUsesWebSearch = usesWebSearch
        completedElsewherePage = nil

        // 页数是阅读器已经知道的事实，不值得交给模型再等一次；把这类
        // 元信息问题即时回答，AI 留给真正需要解释和建立联系的请求。
        if !verification,
           !isAnswerToVerification,
           let localAnswer = localPageCountAnswer(for: request, scope: effectiveScope) {
            let localResponse = LearningResponse(
                text: localAnswer,
                sourceKind: .currentPDF,
                pageIndex: targetPageIndex
            )
            response = localResponse
            isThinking = false
            streamStartDate = nil
            requestTask = nil
            requestPhase = .preparing
            completeDraft(with: localResponse, completion: .completed)
            return
        }

        requestTask = Task {
            // 配置读取很快（钥匙串结果有进程内缓存），放在前面，
            // 扫描页 OCR 需要配置；没配置就直接提示，不必白跑提取。
            let configuration = (
                config: await QwenConfigurationStore.readAsync(),
                prompt: QwenConfigurationStore.readCustomPrompt()
            )
            if Task.isCancelled { return }
            guard let config = configuration.config else {
                hasQwenConfiguration = false
                restoreSubmittedAttachments(submittedAttachments)
                isThinking = false
                streamStartDate = nil
                requestTask = nil
                response = LearningResponse(
                    text: QwenConfigurationStore.hasSavedConfigurationMarker()
                        ? "本机钥匙串暂时没有响应，Satori 没有继续等待。请打开设置，重新保存一次 Qwen 连接后再试。API Key 只会保存在这台 Mac 的钥匙串中。"
                        : "请先在设置中连接 Qwen。百炼 API Key 只会保存在这台 Mac 的钥匙串中。",
                    sourceKind: .inference,
                    pageIndex: targetPageIndex
                )
                return
            }
            hasQwenConfiguration = true
            requestPhase = .preparing

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
                    case let .pageRange(start, end):
                        readingMap ? .chapterMap(start...end) : .pageRange(start...end)
                    case .wholeDocument: .wholeDocument
                    }
                }()
                pageContent = await Task.detached(priority: .userInitiated) {
                    await PDFPageContextExtractor.extract(
                        from: documentURL,
                        scope: extractionScope,
                        qwenConfiguration: config,
                        anchorPage: targetPageIndex
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
                selectionText: effectiveSelectionText,
                regionAnchor: draftRegionAnchor,
                isVerificationResponse: isAnswerToVerification,
                additionalImagesJPEG: submittedAttachments.map(\.jpegData),
                conversationContext: context,
                allowsWebSearch: usesWebSearch,
                instructions: configuration.prompt
            )
            var latestResponse: LearningResponse?
            requestPhase = .waitingForFirstToken
            for await update in assistant.streamExplain(request: request, pageIndex: targetPageIndex) {
                if Task.isCancelled { return }
                if !update.text.isEmpty, update.sourceKind != .inference {
                    requestPhase = .streaming
                }
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

    /// 从本地阅读状态回答“多少页”这类确定性问题，避免一次不必要的模型请求。
    private func localPageCountAnswer(for request: String, scope: LearningContextScope) -> String? {
        let chapterRange = currentTopLevelChapter.flatMap {
            BookChapter.pageRange(for: $0, in: chapters, pageCount: pageCount)
        }
        return ReadingFactAnswer.pageCountAnswer(
            for: request,
            pageCount: pageCount,
            currentPageIndex: pageIndex,
            scope: scope,
            chapterRange: chapterRange
        )
    }

    private func requestNeedsChapterMetadata(_ request: String) -> Bool {
        switch contextMode {
        case .chapter:
            return true
        case .automatic:
            return ReadingScopeInference.referencesChapter(in: request)
        default:
            return false
        }
    }

    private func canResolveChapterScope(for request: String) -> Bool {
        switch contextMode {
        case .chapter:
            guard let activeChapter else { return false }
            return BookChapter.pageRange(for: activeChapter, in: chapters, pageCount: pageCount) != nil
        case .automatic:
            guard let chapter = chapterForInference(for: request) else { return false }
            return BookChapter.pageRange(for: chapter, in: chapters, pageCount: pageCount) != nil
        default:
            return true
        }
    }

    /// 有编号章节时只把“第 N 章 / Chapter N”作为学习章节，排除书名页、
    /// 前言和目录等一级目录；没有编号章节的课程目录回退结构则保留全部一级项。
    private var hasNumberedChapterOutline: Bool {
        chapters.contains { chapter in
            chapter.depth == 0 && ReadingChapterSelector.isNumberedChapterTitle(chapter.title)
        }
    }

    private func isNumberedChapterTitle(_ title: String) -> Bool {
        ReadingChapterSelector.isNumberedChapterTitle(title)
    }

    /// `currentChapter` 可能指向“本节/习题”等叶子节点；“这一章”这类问题
    /// 需要回到最近的学习章节，才能覆盖整章而不是只报当前小节的页数。
    private var currentTopLevelChapter: BookChapter? {
        chapters.last {
            $0.depth == 0
                && ReadingPositionOrdering.isAtOrBefore(
                    pageIndex: $0.pageIndex,
                    normalizedOffset: $0.normalizedOffset,
                    currentPageIndex: pageIndex,
                    currentNormalizedOffset: currentPageOffset
                )
                && (!hasNumberedChapterOutline || isNumberedChapterTitle($0.title))
        }
    }

    /// 发送失败（未配置 / 页提取失败 / 回答报错）时把贴的图还回输入框，
    /// 避免图片悄悄丢失、重试时找不到图。
    private func restoreSubmittedAttachments(_ submitted: [LearningImageAttachment]) {
        submittedAttachmentsForActiveRequest = []
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
        case .page: "暂时无法读取\(readingPageLabel(pageIndex))。请确认 PDF 文件仍然可以打开。"
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
            // 不给时间线留一个「已停止」空壳卡；已提交的图片回到输入框。
            if !submittedAttachmentsForActiveRequest.isEmpty {
                attachments = submittedAttachmentsForActiveRequest
                attachmentStatus = "已停止，图片已保留在输入框，可以修改问题后重试。"
            }
            submittedAttachmentsForActiveRequest = []
            draftQuestion = ""
            draftAttachmentCount = 0
            draftContextScope = .none
            draftSelectionText = nil
            draftSelectionOffset = nil
            draftRegionAnchor = nil
            activeAttachmentPreviews = []
            pendingVerification = false
            pendingVerificationScope = nil
            verificationAnswerMode = false
            draftIsVerification = false
            requestPhase = .preparing
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
            responseDuration: duration,
            selectionText: draftSelectionText,
            selectionOffset: draftSelectionOffset,
            selectionAnchorOffset: draftSelectionOffset,
            regionAnchor: draftRegionAnchor,
            attachmentNotice: finalResponse.attachmentNotice
        )
        turns.append(turn)
        recentCompletedPage = targetPage
        pendingVerification = completion == .completed
            && draftIsVerification
            && targetPage == pageIndex
            && draftPageRevision == readingPositionRevision
        pendingVerificationScope = pendingVerification ? draftContextScope : nil
        verificationAnswerMode = false
        draftIsVerification = false
        requestPhase = .preparing
        draftQuestion = ""
        draftAttachmentCount = 0
        draftContextScope = .none
        draftSelectionText = nil
        draftSelectionOffset = nil
        draftRegionAnchor = nil
        activeAttachmentPreviews = []
        submittedAttachmentsForActiveRequest = []
        response = nil
        persistTurns()
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
        draftSelectionText = nil
        draftRegionAnchor = nil
        response = nil
        activeAttachmentPreviews = []
        submittedAttachmentsForActiveRequest = []
        attachments = []
        attachmentStatus = ""
        completedElsewherePage = nil
        recentCompletedPage = nil
        pendingVerification = false
        pendingVerificationScope = nil
        verificationAnswerMode = false
        draftIsVerification = false
        requestPhase = .preparing
        pendingSelectionPage = nil
        activeSelectionText = nil
        activeSelectionPage = nil
        activeSelectionOffset = nil
        activeRegionAnchor = nil
        activeRegionAttachment = nil
        draftSelectionOffset = nil
        dismissedPageEntryPage = nil
        Task {
            do {
                try await sessionStore.clear(for: documentID)
            } catch {
                historyStatus = "问答记录未能完全清空，请稍后再试。"
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
        guard markedAsConfigured, !isCheckingConfiguration else { return }
        isCheckingConfiguration = true
        Task {
            let hasConfiguration = await QwenConfigurationStore.readAsync() != nil
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
