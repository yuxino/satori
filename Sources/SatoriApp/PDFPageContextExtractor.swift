import AppKit
import PDFKit
import SatoriCore

enum PDFPageContextExtractor {
    static func extract(from url: URL, pageIndex: Int) -> LearningPageContent? {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess { url.stopAccessingSecurityScopedResource() }
        }

        guard let document = PDFDocument(url: url),
              let page = document.page(at: pageIndex) else { return nil }

        let text = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
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
}
