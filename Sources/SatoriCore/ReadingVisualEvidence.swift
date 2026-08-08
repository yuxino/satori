import Foundation

/// Decides when a reliable PDF text layer still needs a page image. Textbooks
/// frequently put “如图 6-2” at the bottom of one page and the actual figure at
/// the top of the next, so the previous page tail is part of the signal.
public enum ReadingVisualEvidence {
    private static let visualPattern = #"(?:如\s*)?(?:图|表)\s*[0-9一二三四五六七八九十百]+(?:\s*[-－—]\s*[0-9]+)?|(?:示意图|结构图|流程图|关系图|框图|时序图)"#

    public static func requiresPageImage(
        currentText: String,
        previousText: String = ""
    ) -> Bool {
        [currentText, String(previousText.suffix(800))].contains {
            $0.range(of: visualPattern, options: .regularExpression) != nil
        }
    }
}
