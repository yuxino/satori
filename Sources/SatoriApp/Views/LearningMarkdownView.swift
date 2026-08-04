import AppKit
import SwiftUI
import SatoriCore

struct LearningMarkdownView: View {
    let markdown: String

    private var blocks: [LearningMarkdownBlock] {
        LearningMarkdownParser.parse(markdown)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language?.uppercased() ?? "代码")
                    .font(.caption2.monospaced().weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("复制代码", systemImage: "doc.on.doc") {
                    copyToPasteboard(content)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .help("复制代码")
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
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.7))
        .clipShape(RoundedRectangle(cornerRadius: SatoriTheme.Radius.sm, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: SatoriTheme.Radius.sm, style: .continuous).stroke(.quaternary))
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .title3.weight(.semibold)
        case 2: .headline
        default: .subheadline.weight(.semibold)
        }
    }

    private func inlineMarkdown(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
