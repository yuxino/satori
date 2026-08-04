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
    }

    static func extract(from url: URL, scope: Scope) -> LearningPageContent? {
        switch scope {
        case let .selection(text):
            let cleaned = ExtractedTextNormalizer.normalize(text)
            guard !cleaned.isEmpty else { return nil }
            return .text(String(cleaned.prefix(24_000)))
        case let .page(pageIndex):
            return extractPage(from: url, pageIndex: pageIndex)
        case .wholeDocument:
            return extractWholeDocument(from: url)
        }
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
