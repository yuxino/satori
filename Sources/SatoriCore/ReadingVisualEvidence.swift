import Foundation

/// Decides when a reliable PDF text layer still needs a page image. Textbooks
/// frequently put “如图 6-2” at the bottom of one page and the actual figure at
/// the top of the next, so the previous page tail is part of the signal.
public enum ReadingVisualEvidence {
    private static let visualPattern = #"(?:如\s*)?(?:图|表)\s*[0-9一二三四五六七八九十百]+(?:\s*[-－—]\s*[0-9]+)?|(?:示意图|结构图|流程图|关系图|框图|时序图)"#

    /// Whether a page's text names a numbered visual or a common textbook
    /// diagram. This is separate from `requiresPageImage`: a previous page
    /// can mention a figure whose body starts on the current page, while the
    /// current page may itself mention a figure whose body continues onto the
    /// next page.
    public static func mentionsVisualReference(in text: String) -> Bool {
        text.range(of: visualPattern, options: .regularExpression) != nil
    }

    public static func requiresPageImage(
        currentText: String,
        previousText: String = ""
    ) -> Bool {
        mentionsVisualReference(in: currentText)
            || mentionsVisualReference(in: String(previousText.suffix(800)))
    }
}
