import AppKit
import SwiftUI
import SatoriCore
import UniformTypeIdentifiers

struct LearningInspector: View {
    enum Mode: String, CaseIterable, Identifiable {
        case understand = "理解"
        case directory = "目录"

        var id: Self { self }
    }

    let documentID: UUID
    let pageIndex: Int
    let directory: [LearningDirectoryItem]
    let documentURL: URL
    let onNavigateToPage: (Int) -> Void
    let onClose: () -> Void

    @Environment(\.openSettings) private var openSettings
    @Environment(\.scenePhase) private var scenePhase
    @State private var mode: Mode = .understand
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
    @State private var requestTask: Task<Void, Never>?
    @State private var showsClearConfirmation = false

    private let sessionStore = LearningSessionStore()
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
            case .understand: understandingView
            case .directory: directoryView
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .task(id: documentID) { await loadHistory() }
        .onAppear { refreshConfigurationState() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refreshConfigurationState() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .qwenConfigurationDidChange)) { _ in
            refreshConfigurationState()
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
        VStack(spacing: 11) {
            HStack {
                Label("学习记录", systemImage: "sparkles")
                    .font(.headline)
                if !turns.isEmpty {
                    Text("\(turns.count)")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(SatoriTheme.lavender)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(SatoriTheme.lavenderSoft, in: Capsule())
                }
                Spacer()
                if mode == .understand, !turns.isEmpty {
                    Button("清空记录", systemImage: "trash") { showsClearConfirmation = true }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.plain)
                        .help("清空这本书的学习记录")
                }
                Button("关闭", systemImage: "xmark", action: onClose)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .help("关闭学习面板")
            }
            Picker("面板内容", selection: $mode) {
                ForEach(Mode.allCases) { item in
                    Text(item.rawValue).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .background(.bar)
    }

    private var understandingView: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        contextCard

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
                        }

                        ForEach(turns) { turn in
                            learningTurnCard(turn)
                                .id(turn.id)
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
                    .padding(14)
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

    private var contextCard: some View {
        HStack(spacing: 10) {
            Image(systemName: "text.viewfinder")
                .foregroundStyle(SatoriTheme.insight)
                .frame(width: 30, height: 30)
                .background(SatoriTheme.insightSoft, in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 1) {
                Text("当前阅读")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("PDF 第 \(pageIndex + 1) 页")
                    .font(.callout.weight(.medium))
            }
            Spacer()
            Text("提问会自动引用此页")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(11)
        .background(.background.opacity(0.78), in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(.quaternary))
    }

    private var promptStarter: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text("从不懂的地方开始")
                    .font(.headline)
                Text("不用整理笔记。先问清一个概念，再沿着答案继续追问。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(quickPrompts, id: \.self) { prompt in
                Button {
                    askAssistant(prompt)
                } label: {
                    HStack {
                        Text(prompt)
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(10)
                .background(.background, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(.quaternary))
            }

            if !hasQwenConfiguration {
                Button("连接 Qwen", systemImage: "key") { openSettings() }
                    .buttonStyle(.bordered)
                    .tint(SatoriTheme.lavender)
            }
        }
        .padding(.vertical, 4)
    }

    private func learningTurnCard(_ turn: LearningTurn) -> some View {
        let isExpanded = expandedTurnIDs.contains(turn.id)
        return VStack(alignment: .leading, spacing: 12) {
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
        .padding(14)
        .background(.background, in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(.quaternary))
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
                HStack(spacing: 9) {
                    ProgressView().controlSize(.small)
                    Text(allowsWebSearch ? "正在理解原文并检索资料…" : "正在理解当前页…")
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
                .padding(.vertical, 6)
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
        .padding(14)
        .background(.background, in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(SatoriTheme.lavender.opacity(isThinking ? 0.45 : 0.18)))
    }

    private func turnQuestionHeader(
        question: String,
        pageIndex: Int,
        attachmentCount: Int,
        createdAt: Date,
        isExpanded: Bool?,
        onToggle: (() -> Void)?
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("我的问题")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(SatoriTheme.lavender)
                Spacer()
                if let isExpanded, let onToggle {
                    Button(isExpanded ? "收起回答" : "展开回答", systemImage: isExpanded ? "chevron.up" : "chevron.down") {
                        onToggle()
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .help(isExpanded ? "收起回答" : "展开回答")
                }
                Text(createdAt, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Text(question)
                .font(.callout.weight(.semibold))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("第 \(pageIndex + 1) 页", systemImage: "doc.text.magnifyingglass") {
                    onNavigateToPage(pageIndex)
                }
                .buttonStyle(.borderless)
                .font(.caption)
                if attachmentCount > 0 {
                    Label("\(attachmentCount) 张附图", systemImage: "photo.on.rectangle.angled")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(11)
        .background(SatoriTheme.lavenderSoft.opacity(0.72), in: RoundedRectangle(cornerRadius: 10))
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
            .foregroundStyle(SatoriTheme.lavender)
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
        VStack(alignment: .leading, spacing: 9) {
            if !attachments.isEmpty { attachmentStrip }

            ZStack(alignment: .topLeading) {
                if question.isEmpty {
                    Text(turns.isEmpty ? "问这一页，也可以附上图片…" : "继续追问这里为什么、再举个例子…")
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 12)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $question)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(minHeight: 68, maxHeight: 104)
                    .onKeyPress(.return, phases: .down) { keyPress in
                        if keyPress.modifiers.contains(.shift) { return .ignored }
                        if canSend { askAssistant() }
                        return .handled
                    }
            }
            .background(.background, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(SatoriTheme.lavender.opacity(0.28)))

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
                .tint(SatoriTheme.lavender)
                .disabled(!isThinking && !canSend)
            }
            Text(composerHint)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(13)
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

    private var directoryView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(Array(directory.enumerated()), id: \.element.id) { index, item in
                    HStack(alignment: .top, spacing: 11) {
                        Text("\(index + 1)")
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .foregroundStyle(item.isComplete ? .secondary : SatoriTheme.lavender)
                            .frame(width: 22, height: 22)
                            .background(SatoriTheme.lavenderSoft, in: Circle())
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title)
                                .font(.callout)
                                .foregroundStyle(item.isComplete ? .secondary : .primary)
                            if let itemPageIndex = item.pageIndex {
                                Button("第 \(itemPageIndex + 1) 页") { onNavigateToPage(itemPageIndex) }
                                    .buttonStyle(.borderless)
                                    .font(.caption)
                            }
                        }
                        Spacer()
                        if item.isComplete {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(.background.opacity(0.7), in: RoundedRectangle(cornerRadius: 10))
                }
            }
            .padding(14)
        }
    }

    private var canSend: Bool {
        !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isThinking
    }

    private var composerHint: String {
        let context = allowsWebSearch ? "发送当前页、最近对话、附件并联网" : "发送当前页、最近对话和附件"
        return "Enter 发送 · Shift+Enter 换行 · \(context)"
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
        excludingTurnID: UUID? = nil
    ) {
        let request = (suppliedQuestion ?? question).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty, !isThinking else { return }

        let targetPageIndex = pageOverride ?? pageIndex
        guard let pageContent = PDFPageContextExtractor.extract(from: documentURL, pageIndex: targetPageIndex) else {
            draftQuestion = request
            draftPageIndex = targetPageIndex
            response = LearningResponse(
                text: "暂时无法读取第 \(targetPageIndex + 1) 页。请确认 PDF 文件仍然可以打开。",
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
                    text: "请先在设置中连接 Qwen。百炼 API Key 只会保存在这台 Mac 的私有配置目录中。",
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
