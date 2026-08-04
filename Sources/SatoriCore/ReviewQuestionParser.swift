import Foundation

/// 解析结果：题目列表 + 无法解析的内容行数，供调用方在结果为空时
/// 给出可读错误，而不是静默吞掉失败行。
public struct ReviewQuestionParseResult: Sendable, Equatable {
    public let questions: [ReviewQuestion]
    /// 非空但无法解析为「问题 | 答案」的行数（代码围栏与空行不计）。
    public let skippedLines: Int

    public init(questions: [ReviewQuestion], skippedLines: Int) {
        self.questions = questions
        self.skippedLines = max(0, skippedLines)
    }
}

/// Parses the model's review output — lines of `问题 | 参考答案` — into
/// `ReviewQuestion`s. Tolerant of markdown fences and stray bullets so a
/// slightly-off response still yields usable questions.
public enum ReviewQuestionParser {
    public static func parse(_ text: String, pageIndex: Int) -> [ReviewQuestion] {
        parseDetailed(text, pageIndex: pageIndex).questions
    }

    /// 同 `parse`，但额外报告有多少行内容未能解析。
    public static func parseDetailed(_ text: String, pageIndex: Int) -> ReviewQuestionParseResult {
        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n")
            .map(String.init)

        var questions: [ReviewQuestion] = []
        var skippedLines = 0
        for raw in lines {
            var line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            // Strip fenced-code markers and list bullets.
            if line.hasPrefix("```") { continue }
            for prefix in ["- ", "* ", "• ", "1. ", "2. ", "3. ", "4. ", "5. "] where line.hasPrefix(prefix) {
                line = String(line.dropFirst(prefix.count))
                break
            }
            line = line.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            // Split on the first "|" or full-width "｜".
            let separators = [" | ", "|", "｜"]
            guard let sep = separators.first(where: { line.contains($0) }),
                  let range = line.range(of: sep) else {
                skippedLines += 1
                continue
            }
            let question = line[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
            let answer = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
            guard !question.isEmpty, !answer.isEmpty else {
                skippedLines += 1
                continue
            }
            questions.append(
                ReviewQuestion(question: String(question), answer: String(answer), pageIndex: pageIndex)
            )
        }
        return ReviewQuestionParseResult(questions: questions, skippedLines: skippedLines)
    }
}
