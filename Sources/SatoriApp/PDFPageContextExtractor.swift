import AppKit
import PDFKit
import SatoriCore

enum PDFPageContextExtractor {
    /// What slice of the PDF a question should be grounded in.
    enum Scope: Equatable {
        /// Text the reader highlighted on the page.
        case selection(String)
        /// The page currently on screen.
        case page(Int)
        /// The whole book, as concatenated page text.
        case wholeDocument
        /// A highlighted passage together with the pages around it, so the AI
        /// can answer with the surrounding context (the way Marginalia pulls
        /// the few paragraphs before and after a selection).
        case selectionWithContext(String, pageIndex: Int)
    }

    static func extract(from url: URL, scope: Scope) -> LearningPageContent? {
        switch scope {
        case let .selection(text):
            let cleaned = ExtractedTextNormalizer.normalize(text)
            guard !cleaned.isEmpty else { return nil }
            return .text(String(cleaned.prefix(24_000)))
        case let .selectionWithContext(text, pageIndex):
            return extractSelectionWithContext(from: url, selected: text, pageIndex: pageIndex)
        case let .page(pageIndex):
            return extractPage(from: url, pageIndex: pageIndex)
        case .wholeDocument:
            return extractWholeDocument(from: url)
        }
    }

    /// Highlights the selected passage but keeps the page it came from and the
    /// neighboring pages so the model isn't answering in a vacuum.
    private static func extractSelectionWithContext(from url: URL, selected: String, pageIndex: Int) -> LearningPageContent? {
        let cleanedSelection = ExtractedTextNormalizer.normalize(selected)
        guard !cleanedSelection.isEmpty else { return nil }

        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess { url.stopAccessingSecurityScopedResource() }
        }
        guard let document = PDFDocument(url: url) else {
            return .text(String(cleanedSelection.prefix(24_000)))
        }

        var context = ""
        // Page before, the selection's page, page after.
        for index in [pageIndex - 1, pageIndex, pageIndex + 1] {
            guard index >= 0, index < document.pageCount,
                  let page = document.page(at: index) else { continue }
            let text = ExtractedTextNormalizer.normalize(page.string ?? "")
            guard !text.isEmpty else { continue }
            context += "【第 \(index + 1) 页】\n\(text)\n\n"
        }

        let header = "用户选中了下面这段文字，并附上了它所在页及前后页作为上下文：\n\n【选中的内容】\n\(cleanedSelection)\n\n【上下文】\n"
        let combined = header + context
        return .text(String(combined.prefix(24_000)))
    }

    static func extract(from url: URL, pageIndex: Int) -> LearningPageContent? {
        extract(from: url, scope: .page(pageIndex))
    }

    private static func extractPage(from url: URL, pageIndex: Int) -> LearningPageContent? {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess { url.stopAccessingSecurityScopedResource() }
        }

        guard let document = PDFDocument(url: url),
              let page = document.page(at: pageIndex) else { return nil }

        let text = ExtractedTextNormalizer.normalize(page.string ?? "")
        if text.count >= 40 {
            return .text(String(text.prefix(24_000)))
        }

        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let targetWidth: CGFloat = 1_400
        let size = NSSize(width: targetWidth, height: targetWidth * bounds.height / bounds.width)
        let image = page.thumbnail(of: size, for: .mediaBox)
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.82]) else { return nil }
        return .imageJPEG(jpeg)
    }

    private static func extractWholeDocument(from url: URL) -> LearningPageContent? {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess { url.stopAccessingSecurityScopedResource() }
        }

        guard let document = PDFDocument(url: url), document.pageCount > 0 else { return nil }

        var assembled = ""
        let limit = 60_000
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            let text = ExtractedTextNormalizer.normalize(page.string ?? "")
            guard !text.isEmpty else { continue }
            assembled += "【第 \(pageIndex + 1) 页】\n\(text)\n\n"
            if assembled.count >= limit { break }
        }

        let trimmed = assembled.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return .text(String(trimmed.prefix(limit)))
    }
}
