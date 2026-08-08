import Foundation

/// Small page-level signals that let the reading assistant change its stance
/// without turning every page into a workflow. This is deliberately narrower
/// than a document classifier: it only answers whether the current page looks
/// like an exercise/question page.
public enum ReadingPagePurpose {
    private static let standaloneHeadings = [
        "习题", "思考题", "练习题", "课后题", "课后练习", "自测题", "实验题",
        "题型举例", "单项选择题", "选择题", "填空题", "简答题", "综合题"
    ]

    /// Returns true for a page headed as an exercise section or for a
    /// continuation page with several question-shaped numbered items.
    /// Ordinary prose that merely mentions “习题册” should stay ordinary.
    public static func isExercisePage(_ text: String) -> Bool {
        let lines = text
            .components(separatedBy: .newlines)
            .map(compact)
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return false }

        if lines.contains(where: isStandaloneExerciseHeading) {
            return true
        }

        // A continued exercise page may no longer repeat the “习题” heading.
        // Require both several numbered entries and question-like language so
        // a normal page's “1. / 2. / 3.” section list is not misclassified.
        let numberedItems = lines.filter {
            $0.range(of: #"^(?:[0-9]{1,2}[\.、)）]|[一二三四五六七八九十]+[、.])"#, options: .regularExpression) != nil
        }.count
        let questionLanguage = [
            "请问", "什么是", "如何", "怎样", "为什么", "假定", "试问", "设计",
            "画出", "计算", "说明", "求", "能否"
        ]
        let hasQuestionLanguage = questionLanguage.contains { text.contains($0) }
        let questionMarks = text.filter { $0 == "？" || $0 == "?" }.count
        return numberedItems >= 4 && (hasQuestionLanguage || questionMarks >= 2)
    }

    private static func isStandaloneExerciseHeading(_ line: String) -> Bool {
        standaloneHeadings.contains { heading in
            line == heading
                || line.hasSuffix(heading) && line.count <= heading.count + 8
                || line.hasPrefix(heading) && line.count <= heading.count + 8
        }
    }

    /// PDF text extraction and OCR can put spaces between Chinese glyphs.
    /// Remove only whitespace here; punctuation and Latin/code tokens remain
    /// available to the continuation-page heuristic.
    private static func compact(_ value: String) -> String {
        value.replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
    }
}
