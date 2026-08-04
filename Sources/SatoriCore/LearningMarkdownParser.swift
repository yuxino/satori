import Foundation

public struct LearningOrderedItem: Equatable, Sendable {
    public let number: Int
    public let text: String

    public init(number: Int, text: String) {
        self.number = number
        self.text = text
    }
}

public struct LearningTaskItem: Equatable, Sendable {
    public let checked: Bool
    public let text: String

    public init(checked: Bool, text: String) {
        self.checked = checked
        self.text = text
    }
}

public enum LearningMarkdownBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case unorderedList([String])
    case orderedList([LearningOrderedItem])
    case taskList([LearningTaskItem])
    case quote(String)
    case code(language: String?, content: String)
    case table(headers: [String], rows: [[String]])
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

            if let task = taskItem(from: line) {
                flushParagraph()
                var items = [task]
                index += 1
                while index < lines.count, let next = taskItem(from: lines[index].trimmingCharacters(in: .whitespaces)) {
                    items.append(next)
                    index += 1
                }
                blocks.append(.taskList(items))
                continue
            }

            if let table = table(from: lines, index: &index) {
                flushParagraph()
                blocks.append(table)
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

    /// `- [ ] 待办` / `- [x] 完成` 任务行（AI 回答里常见的待办清单）。
    private static func taskItem(from line: String) -> LearningTaskItem? {
        for prefix in ["- [x] ", "- [X] ", "- [ ] ", "* [x] ", "* [X] ", "* [ ] "] where line.hasPrefix(prefix) {
            let checked = prefix.contains("[x]") || prefix.contains("[X]")
            let remainder = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            return LearningTaskItem(checked: checked, text: remainder)
        }
        return nil
    }

    /// 标准 GFM 表格：当前行含 `|` 且下一行是 `---|---` 分隔行，则收集后续
    /// 表行直到不再以 `|` 分段。行内单元格保留原样，交给行内渲染。
    private static func table(from lines: [String], index: inout Int) -> LearningMarkdownBlock? {
        guard index + 1 < lines.count else { return nil }
        let first = lines[index].trimmingCharacters(in: .whitespaces)
        let separator = lines[index + 1].trimmingCharacters(in: .whitespaces)
        guard first.contains("|"), isTableSeparator(separator) else { return nil }
        let headers = splitTableRow(first)
        guard !headers.isEmpty else { return nil }
        var rows: [[String]] = []
        var cursor = index + 2
        while cursor < lines.count {
            let candidate = lines[cursor].trimmingCharacters(in: .whitespaces)
            guard candidate.contains("|") else { break }
            rows.append(splitTableRow(candidate))
            cursor += 1
        }
        index = cursor
        return .table(headers: headers, rows: rows)
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "|")))
        guard !trimmed.isEmpty else { return false }
        let cells = trimmed.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        return cells.allSatisfy { cell in
            let cleaned = cell.replacingOccurrences(of: ":", with: "")
            return !cleaned.isEmpty && cleaned.allSatisfy { $0 == "-" }
        }
    }

    private static func splitTableRow(_ line: String) -> [String] {
        var cells = line.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        if cells.first?.isEmpty == true { cells.removeFirst() }
        if cells.last?.isEmpty == true { cells.removeLast() }
        return cells
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

    private static func orderedItem(from line: String) -> LearningOrderedItem? {
        guard let separator = line.firstIndex(of: ".") else { return nil }
        let digits = line[..<separator]
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber), let number = Int(digits) else { return nil }
        let remainder = line[line.index(after: separator)...]
        guard remainder.hasPrefix(" ") else { return nil }
        return LearningOrderedItem(number: number, text: remainder.trimmingCharacters(in: .whitespaces))
    }
}
