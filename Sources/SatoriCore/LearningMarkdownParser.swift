import Foundation

public enum LearningMarkdownBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case unorderedList([String])
    case orderedList([String])
    case quote(String)
    case code(language: String?, content: String)
    case divider
}

public enum LearningMarkdownParser {
    public static func parse(_ markdown: String) -> [LearningMarkdownBlock] {
        let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var blocks: [LearningMarkdownBlock] = []
        var paragraph: [String] = []
        var index = 0

        func flushParagraph() {
            let text = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { blocks.append(.paragraph(text)) }
            paragraph.removeAll(keepingCapacity: true)
        }

        while index < lines.count {
            let rawLine = lines[index]
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if line.isEmpty {
                flushParagraph()
                index += 1
                continue
            }

            if line.hasPrefix("```") {
                flushParagraph()
                let languageText = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var codeLines: [String] = []
                index += 1
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    codeLines.append(lines[index])
                    index += 1
                }
                if index < lines.count { index += 1 }
                blocks.append(.code(language: languageText.isEmpty ? nil : languageText, content: codeLines.joined(separator: "\n")))
                continue
            }

            if let heading = heading(from: line) {
                flushParagraph()
                blocks.append(heading)
                index += 1
                continue
            }

            if line == "---" || line == "***" || line == "___" {
                flushParagraph()
                blocks.append(.divider)
                index += 1
                continue
            }

            if let item = unorderedItem(from: line) {
                flushParagraph()
                var items = [item]
                index += 1
                while index < lines.count, let next = unorderedItem(from: lines[index].trimmingCharacters(in: .whitespaces)) {
                    items.append(next)
                    index += 1
                }
                blocks.append(.unorderedList(items))
                continue
            }

            if let item = orderedItem(from: line) {
                flushParagraph()
                var items = [item]
                index += 1
                while index < lines.count, let next = orderedItem(from: lines[index].trimmingCharacters(in: .whitespaces)) {
                    items.append(next)
                    index += 1
                }
                blocks.append(.orderedList(items))
                continue
            }

            if line.hasPrefix(">") {
                flushParagraph()
                var quoteLines: [String] = []
                while index < lines.count {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    guard candidate.hasPrefix(">") else { break }
                    quoteLines.append(String(candidate.dropFirst()).trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                blocks.append(.quote(quoteLines.joined(separator: "\n")))
                continue
            }

            paragraph.append(rawLine)
            index += 1
        }

        flushParagraph()
        return blocks
    }

    private static func heading(from line: String) -> LearningMarkdownBlock? {
        let hashCount = line.prefix { $0 == "#" }.count
        if (1...4).contains(hashCount) {
            let remainder = String(line.dropFirst(hashCount))
            if remainder.hasPrefix(" ") {
                return .heading(level: hashCount, text: remainder.trimmingCharacters(in: .whitespaces))
            }
        }

        if line.count <= 80,
           line.hasPrefix("**"), line.hasSuffix("**"), line.count > 4 {
            let inner = String(line.dropFirst(2).dropLast(2))
            if !inner.contains("**") {
                return .heading(level: 3, text: inner.trimmingCharacters(in: .whitespaces))
            }
        }
        return nil
    }

    private static func unorderedItem(from line: String) -> String? {
        for prefix in ["- ", "* ", "• "] where line.hasPrefix(prefix) {
            return String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    private static func orderedItem(from line: String) -> String? {
        guard let separator = line.firstIndex(of: ".") else { return nil }
        let number = line[..<separator]
        guard !number.isEmpty, number.allSatisfy(\.isNumber) else { return nil }
        let remainder = line[line.index(after: separator)...]
        guard remainder.hasPrefix(" ") else { return nil }
        return remainder.trimmingCharacters(in: .whitespaces)
    }
}
