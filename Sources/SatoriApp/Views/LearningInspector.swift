import SwiftUI
import SatoriCore
import UniformTypeIdentifiers

struct LearningInspector: View {
    enum Mode: String, CaseIterable, Identifiable {
        case understand = "理解"
        case directory = "目录"

        var id: Self { self }
    }

    let pageIndex: Int
    let directory: [LearningDirectoryItem]
    let documentURL: URL
    let onClose: () -> Void
    @Environment(\.openSettings) private var openSettings
    @Environment(\.scenePhase) private var scenePhase
    @State private var mode: Mode = .understand
    @State private var question = ""
    @State private var response: LearningResponse?
    @State private var isThinking = false
    @State private var hasQwenConfiguration = false
    @State private var allowsWebSearch = false
    @State private var attachments: [LearningImageAttachment] = []
    @State private var isImportingImage = false
    @State private var attachmentStatus = ""
    @State private var lastQuestion = ""
    @State private var lastAttachmentNames: [String] = []
    @State private var requestTask: Task<Void, Never>?

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
            case .understand:
                understandingView
            case .directory:
                directoryView
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .onAppear { hasQwenConfiguration = QwenConfigurationStore.read() != nil }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { hasQwenConfiguration = QwenConfigurationStore.read() != nil }
        }
        .onReceive(NotificationCenter.default.publisher(for: .qwenConfigurationDidChange)) { _ in
            hasQwenConfiguration = QwenConfigurationStore.read() != nil
        }
        .fileImporter(
            isPresented: $isImportingImage,
            allowedContentTypes: [.image],
            allowsMultipleSelection: true,
            onCompletion: importImages
        )
        .onDisappear { requestTask?.cancel() }
    }

    private var inspectorHeader: some View {
        VStack(spacing: 12) {
            HStack {
                Label("学习助手", systemImage: "sparkles")
                    .font(.headline)
                Spacer()
                Button("关闭", systemImage: "xmark", action: onClose)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .help("关闭理解面板")
            }
            Picker("面板内容", selection: $mode) {
                ForEach(Mode.allCases) { item in
                    Text(item.rawValue).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .padding(16)
        .background(.bar)
    }

    private var understandingView: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        contextCard

                        if !lastQuestion.isEmpty {
                            submittedQuestionCard
                        }

                        if let response {
                            responseCard(response)
                        } else {
                            promptStarter
                        }

                        Color.clear
                            .frame(height: 1)
                            .id("learning-response-bottom")
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: response?.text) { _, _ in
                    proxy.scrollTo("learning-response-bottom", anchor: .bottom)
                }
            }

            Divider()
            composer
        }
    }

    private var contextCard: some View {
        HStack(spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 9)
                    .fill(SatoriTheme.insightSoft)
                    .frame(width: 38, height: 38)
                Image(systemName: "text.viewfinder")
                    .foregroundStyle(SatoriTheme.insight)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("当前上下文")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("PDF 第 \(pageIndex + 1) 页")
                    .font(.callout.weight(.medium))
            }
            Spacer()
        }
        .padding(12)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))
    }

    private var promptStarter: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text("从不懂的地方开始")
                    .font(.headline)
                Text("提问时会自动带上当前页。Satori 会把原文依据和 AI 推断分开显示。")
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
                        Image(systemName: "arrow.up.left")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(11)
                .background(.background, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary))
            }

            if !hasQwenConfiguration {
                Button("连接 Qwen", systemImage: "key") { openSettings() }
                    .buttonStyle(.bordered)
                    .tint(SatoriTheme.lavender)
            }
        }
    }

    private func responseCard(_ response: LearningResponse) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(
                    isThinking ? "Qwen 正在回答" : response.sourceKind.localizedTitle,
                    systemImage: isThinking ? "sparkles" : "checkmark.seal"
                )
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(SatoriTheme.lavender)
                Spacer()
                if let pageIndex = response.pageIndex {
                    Text("第 \(pageIndex + 1) 页")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if response.text.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(allowsWebSearch ? "正在阅读当前页并搜索资料…" : "正在阅读当前页…")
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
            } else {
                Text(response.text)
                    .font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !response.citations.isEmpty {
                Divider()
                Text("网页来源")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(response.citations) { citation in
                    Link(destination: citation.url) {
                        Label(citation.title, systemImage: "arrow.up.right.square")
                            .font(.caption)
                            .lineLimit(2)
                    }
                }
            }
        }
        .padding(14)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))
    }

    private var submittedQuestionCard: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("我的问题")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(lastQuestion)
                .font(.callout)
                .textSelection(.enabled)
            if !lastAttachmentNames.isEmpty {
                Label("附加了 \(lastAttachmentNames.count) 张图片", systemImage: "photo.on.rectangle.angled")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SatoriTheme.lavenderSoft.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !attachments.isEmpty {
                attachmentStrip
            }

            ZStack(alignment: .topLeading) {
                if question.isEmpty {
                    Text("问这一页，也可以附上图片…")
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 12)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $question)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(minHeight: 72, maxHeight: 110)
                    .onKeyPress(.return, phases: .down) { keyPress in
                        if keyPress.modifiers.contains(.shift) { return .ignored }
                        if canSend { askAssistant() }
                        return .handled
                    }
            }
            .background(.background, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(SatoriTheme.lavender.opacity(0.25)))

            if !attachmentStatus.isEmpty {
                Text(attachmentStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("添加图片", systemImage: "photo.badge.plus") {
                    isImportingImage = true
                }
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
                    if isThinking {
                        stopAssistant()
                    } else {
                        askAssistant()
                    }
                } label: {
                    if isThinking {
                        Label("停止", systemImage: "stop.fill")
                    } else {
                        Label("发送", systemImage: "arrow.up")
                    }
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
        .padding(14)
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
        let context = allowsWebSearch ? "会发送当前页、附件并联网" : "只在提问时发送当前页和附件"
        return "Enter 发送 · Shift+Enter 换行 · \(context)"
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
                            if let pageIndex = item.pageIndex {
                                Text("第 \(pageIndex + 1) 页")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
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
            .padding(16)
        }
    }

    private func askAssistant(_ suppliedQuestion: String? = nil) {
        let request = (suppliedQuestion ?? question).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty else { return }
        guard let configuration = QwenConfigurationStore.read() else {
            hasQwenConfiguration = false
            response = LearningResponse(
                text: "请先在设置中连接 Qwen。百炼 API Key 只会保存在 macOS 钥匙串中。",
                sourceKind: .inference,
                pageIndex: pageIndex
            )
            return
        }
        guard let pageContent = PDFPageContextExtractor.extract(from: documentURL, pageIndex: pageIndex) else {
            response = LearningResponse(
                text: "暂时无法读取当前页。请确认 PDF 文件仍然可以打开。",
                sourceKind: .inference,
                pageIndex: pageIndex
            )
            return
        }
        let submittedAttachments = attachments
        lastQuestion = request
        lastAttachmentNames = submittedAttachments.map(\.name)
        question = ""
        attachments = []
        attachmentStatus = ""
        response = LearningResponse(text: "", sourceKind: .currentPDF, pageIndex: pageIndex)
        isThinking = true
        let assistant = QwenLearningAssistant(
            apiKey: configuration.apiKey,
            modelID: configuration.modelID,
            pageContent: pageContent,
            additionalImagesJPEG: submittedAttachments.map(\.jpegData),
            allowsWebSearch: allowsWebSearch
        )
        requestTask = Task {
            for await update in assistant.streamExplain(request: request, pageIndex: pageIndex) {
                if Task.isCancelled { break }
                response = update
            }
            isThinking = false
            requestTask = nil
        }
    }

    private func stopAssistant() {
        requestTask?.cancel()
        requestTask = nil
        isThinking = false
        if response?.text.isEmpty == true {
            response = LearningResponse(text: "已停止这次回答。", sourceKind: .inference, pageIndex: pageIndex)
        }
    }

    private func importImages(_ result: Result<[URL], Error>) {
        do {
            let urls = try result.get()
            let remaining = max(0, 4 - attachments.count)
            let selected = Array(urls.prefix(remaining))
            attachments.append(contentsOf: try selected.map(LearningImageAttachmentLoader.load))
            attachmentStatus = urls.count > remaining ? "每次最多附加 4 张图片，其余图片没有加入。" : ""
        } catch {
            attachmentStatus = error.localizedDescription
        }
    }
}
