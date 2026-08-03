import SwiftUI
import SatoriCore

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
    @State private var hasAPIKey = false
    @State private var allowsWebSearch = false

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
        .onAppear { hasAPIKey = OpenAIKeyStore.read()?.isEmpty == false }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { hasAPIKey = OpenAIKeyStore.read()?.isEmpty == false }
        }
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
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    contextCard

                    if let response {
                        responseCard(response)
                    } else {
                        promptStarter
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
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
                    question = prompt
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

            if !hasAPIKey {
                Button("连接 OpenAI", systemImage: "key") { openSettings() }
                    .buttonStyle(.bordered)
                    .tint(SatoriTheme.lavender)
            }
        }
    }

    private func responseCard(_ response: LearningResponse) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(response.sourceKind.localizedTitle, systemImage: "checkmark.seal")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(SatoriTheme.lavender)
                Spacer()
                if let pageIndex = response.pageIndex {
                    Text("第 \(pageIndex + 1) 页")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Text(response.text)
                .font(.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
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

    private var composer: some View {
        VStack(spacing: 10) {
            TextEditor(text: $question)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minHeight: 72, maxHeight: 110)
                .background(.background, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(SatoriTheme.lavender.opacity(0.25)))

            HStack {
                Toggle(isOn: $allowsWebSearch) {
                    Label("联网", systemImage: "globe")
                }
                .toggleStyle(.button)
                .controlSize(.small)
                .help("允许这次提问使用 OpenAI 网页搜索")
                Spacer()
                Button {
                    askAssistant()
                } label: {
                    if isThinking {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("帮我理解", systemImage: "arrow.up")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(SatoriTheme.lavender)
                .disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isThinking)
            }
            Text(allowsWebSearch ? "发送当前页，并允许 OpenAI 搜索网页" : "仅在提问时发送当前 PDF 第 \(pageIndex + 1) 页")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(.bar)
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

    private func askAssistant() {
        let request = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty else { return }
        guard let apiKey = OpenAIKeyStore.read(), !apiKey.isEmpty else {
            hasAPIKey = false
            response = LearningResponse(
                text: "请先在设置中连接 OpenAI。API Key 只会保存在 macOS 钥匙串中。",
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
        isThinking = true
        let assistant = OpenAILearningAssistant(
            apiKey: apiKey,
            pageContent: pageContent,
            allowsWebSearch: allowsWebSearch
        )
        Task {
            response = await assistant.explain(request: request, pageIndex: pageIndex)
            isThinking = false
        }
    }
}
