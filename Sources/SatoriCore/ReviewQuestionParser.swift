import Foundation

/// Parses the model's review output — lines of `问题 | 参考答案` — into
/// `ReviewQuestion`s. Tolerant of markdown fences and stray bullets so a
/// slightly-off response still yields usable questions.
public enum ReviewQuestionParser {
    public static func parse(_ text: String, pageIndex: Int) -> [ReviewQuestion] {
        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n")
            .map(String.init)

        var questions: [ReviewQuestion] = []
        for raw in lines {
            var line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            // Strip fenced-code markers and list bullets.
            if line.hasPrefix("```") { continue }
            for prefix in ["- ", "* ", "• ", "1. ", "2. ", "3. ", "4. ", "5. "] where line.hasPrefix(prefix) {
                line = String(line.dropFirst(prefix.count))
                break
            }
            line = line.trimmingCharacters(in: .whitespaces)

            // Split on the first "|" or full-width "｜".
            let separators = [" | ", "|", "｜"]
            guard let sep = separators.first(where: { line.contains($0) }),
                  let range = line.range(of: sep) else { continue }
            let question = line[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
            let answer = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
            guard !question.isEmpty, !answer.isEmpty else { continue }
            questions.append(
                ReviewQuestion(question: String(question), answer: String(answer), pageIndex: pageIndex)
            )
        }
        return questions
    }
}
