import AppKit
import SwiftUI
import SatoriCore

struct LearningMarkdownView: View {
    let markdown: String

    /// 流式回答期间每次 delta 都重解析全文会 O(n²) 卡顿，这里把「渲染用文本」
    /// 与「原始输入」解耦：增长 ≥40 字符立即渲染，否则 120ms 后兜底渲染，
    /// 保证收尾的小段文本也会出现。
    @State private var displayedMarkdown = ""
    @State private var throttleWork: DispatchWorkItem?

    private var blocks: [LearningMarkdownBlock] {
        LearningMarkdownParser.parse(displayedMarkdown)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { displayedMarkdown = markdown }
        .onChange(of: markdown) { _, newValue in
            throttleWork?.cancel()
            if newValue.count - displayedMarkdown.count >= 40 {
                displayedMarkdown = newValue
                return
            }
            let work = DispatchWorkItem { displayedMarkdown = newValue }
            throttleWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
        }
    }

    @ViewBuilder
    private func blockView(_ block: LearningMarkdownBlock) -> some View {
        switch block {
        case let .heading(level, text):
            Text(inlineMarkdown(text))
                .font(headingFont(level))
                .foregroundStyle(.primary)
                .padding(.top, level <= 2 ? 3 : 1)
        case let .paragraph(text):
            Text(inlineMarkdown(text))
                .font(.body)
                .lineSpacing(5)
                .fixedSize(horizontal: false, vertical: true)
        case let .unorderedList(items):
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        Circle()
                            .fill(SatoriTheme.accent.opacity(0.78))
                            .frame(width: 5, height: 5)
                        Text(inlineMarkdown(item))
                            .font(.body)
                            .lineSpacing(4)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case let .orderedList(items):
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        Text("\(item.number)")
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .foregroundStyle(SatoriTheme.accent)
                            .frame(width: 20, height: 20)
                            .background(SatoriTheme.accentWash, in: Circle())
                        Text(inlineMarkdown(item.text))
                            .font(.body)
                            .lineSpacing(4)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case let .taskList(items):
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        Image(systemName: item.checked ? "checkmark.square.fill" : "square")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(item.checked ? SatoriTheme.accent : Color.secondary.opacity(0.55))
                        Text(inlineMarkdown(item.text))
                            .font(.body)
                            .lineSpacing(4)
                            .strikethrough(item.checked, color: .secondary.opacity(0.65))
                            .foregroundStyle(item.checked ? .secondary : .primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case let .table(headers, rows):
            markdownTable(headers: headers, rows: rows)
        case let .quote(text):
            HStack(alignment: .top, spacing: 11) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(SatoriTheme.gold.opacity(0.6))
                    .frame(width: 3)
                Text(inlineMarkdown(text))
                    .font(.callout.italic())
                    .lineSpacing(4)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 2)
        case let .code(language, content):
            codeBlock(language: language, content: content)
        case .divider:
            Divider().padding(.vertical, 2)
        }
    }

    private func codeBlock(language: String?, content: String) -> some View {
        CodeBlockView(language: language, content: content)
    }

    /// GFM 表格：表头加粗 + 底部分隔线，偶数行浅色斑马纹，单元格自动均分
    /// 列宽并对齐。空单元格用占位，保证不同行数也排得齐。
    ///
    /// 窄面板（学习面板约 360pt）里列一多就会被压成几列挤在一起，这里用
    /// ViewThatFits 自适应：等宽均分放得下就用原样式；放不下则整表横滚，
    /// 每列固定 96pt 保证可读，且所有行同宽、列仍然对齐。
    private func markdownTable(headers: [String], rows: [[String]]) -> some View {
        let columnCount = max(headers.count, rows.map(\.count).max() ?? 0)
        return ViewThatFits(in: .horizontal) {
            tableContent(headers: headers, rows: rows, columnCount: columnCount, fixedColumnWidth: nil)
            ScrollView(.horizontal, showsIndicators: false) {
                tableContent(headers: headers, rows: rows, columnCount: columnCount, fixedColumnWidth: 96)
            }
        }
        .padding(.vertical, 2)
    }

    private func tableContent(headers: [String], rows: [[String]], columnCount: Int, fixedColumnWidth: CGFloat?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            tableRow(headers, count: columnCount, isHeader: true, fixedColumnWidth: fixedColumnWidth)
                .background(SatoriTheme.accentWash.opacity(0.55))
            Rectangle()
                .fill(SatoriTheme.hairline)
                .frame(height: 1)
            ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                tableRow(row, count: columnCount, isHeader: false, fixedColumnWidth: fixedColumnWidth)
                    .background(rowIndex.isMultiple(of: 2) ? Color.primary.opacity(0.028) : Color.clear)
            }
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: SatoriTheme.Radius.sm, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: SatoriTheme.Radius.sm, style: .continuous).stroke(.quaternary))
    }

    private func tableRow(_ cells: [String], count: Int, isHeader: Bool, fixedColumnWidth: CGFloat?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            ForEach(0..<count, id: \.self) { column in
                Text(inlineMarkdown(cells.indices.contains(column) ? cells[column] : ""))
                    .font(isHeader ? .callout.weight(.semibold) : .callout)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(
                        minWidth: fixedColumnWidth,
                        maxWidth: fixedColumnWidth == nil ? .infinity : nil,
                        alignment: .leading
                    )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .title3.weight(.semibold)
        case 2: .headline
        default: .subheadline.weight(.semibold)
        }
    }

    /// 行内 Markdown → AttributedString。给行内代码加淡紫 chip 背景和等宽
    /// 字体，亮暗模式都清晰可辨（系统默认的行内代码样式在深色下几乎看不见）。
    private func inlineMarkdown(_ text: String) -> AttributedString {
        guard var attributed = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) else { return AttributedString(text) }
        for run in attributed.runs {
            guard let intent = run.inlinePresentationIntent, intent.contains(.code) else { continue }
            attributed[run.range].backgroundColor = SatoriThemeAppKit.accent.withAlphaComponent(0.13)
            attributed[run.range].foregroundColor = .labelColor
            attributed[run.range].font = .monospacedSystemFont(ofSize: 12, weight: .medium)
            // 移除系统的 code intent，避免 Text 用默认样式覆盖我们的 chip。
            attributed[run.range].inlinePresentationIntent = intent.subtracting(.code)
        }
        return attributed
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// A fenced code block with copy and, when the language is runnable, a "运行"
/// button that executes the snippet locally and expands its output below.
private struct CodeBlockView: View {
    let language: String?
    let content: String

    @State private var runState: RunState = .idle
    @State private var copied = false

    private enum RunState {
        case idle
        case running
        case finished(CodeRunResult)
    }

    private var runnable: CodeRunner.Language? {
        CodeRunner.Language.recognized(language)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language?.uppercased() ?? "代码")
                    .font(.caption2.monospaced().weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if runnable != nil, !isRunning {
                    Button("运行", systemImage: "play.fill") { run() }
                        .font(.caption2.weight(.semibold))
                        .labelStyle(.titleAndIcon)
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .tint(SatoriTheme.accent)
                        .help("在本机运行这段代码")
                }
                if isRunning {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.mini)
                        Text("运行中")
                            .font(.caption2)
                    }
                    .foregroundStyle(.secondary)
                }
                Button {
                    copyToPasteboard(content)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.2))
                        copied = false
                    }
                } label: {
                    Label(copied ? "已复制" : "复制",
                          systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .foregroundStyle(copied ? Color.green : Color.secondary)
                .help("复制代码")
                .animation(SatoriTheme.Motion.quick, value: copied)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(Color.primary.opacity(0.045))

            ScrollView(.horizontal, showsIndicators: false) {
                Text(content)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(11)
            }

            if let result = finishedResult {
                Divider()
                runOutputView(result)
            }
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.7))
        .clipShape(RoundedRectangle(cornerRadius: SatoriTheme.Radius.sm, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: SatoriTheme.Radius.sm, style: .continuous).stroke(.quaternary))
    }

    private var isRunning: Bool {
        if case .running = runState { return true }
        return false
    }

    private var finishedResult: CodeRunResult? {
        if case let .finished(result) = runState { return result }
        return nil
    }

    private func run() {
        guard let runnable else { return }
        runState = .running
        let code = content
        Task {
            let result = await CodeRunner.run(code: code, language: runnable)
            runState = .finished(result)
        }
    }

    private func runOutputView(_ result: CodeRunResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: result.exitCode == 0 ? "checkmark.circle" : "xmark.octagon")
                    .foregroundStyle(result.exitCode == 0 ? .green : .red)
                Text(result.timedOut ? "运行超时，已停止" : (result.exitCode == 0 ? "运行完成" : "运行出错"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if result.exitCode != 0 && !result.timedOut {
                    Text("退出码 \(result.exitCode)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            }
            if !result.stdout.isEmpty {
                Text(result.stdout)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
            }
            if !result.stderr.isEmpty {
                Text(result.stderr)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color.red.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(10)
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
