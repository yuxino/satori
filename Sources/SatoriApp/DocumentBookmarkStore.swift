import Foundation
import PDFKit
import SatoriCore

enum DocumentBookmarkStore {
    static func makeDocument(from url: URL) throws -> StudyDocument {
        let bookmarkData = try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        let inspection = PDFDocumentInspector.inspect(url: url)
        return StudyDocument(
            displayName: url.deletingPathExtension().lastPathComponent,
            localPath: url.path,
            bookmarkData: bookmarkData,
            pageCount: inspection.pageCount,
            contentKind: inspection.contentKind
        )
    }

    static func resolveURL(for document: StudyDocument) -> URL? {
        if let bookmarkData = document.bookmarkData {
            var isStale = false
            if let url = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                return url
            }
        }
        let url = URL(fileURLWithPath: document.localPath)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

private enum PDFDocumentInspector {
    struct Result {
        let pageCount: Int
        let contentKind: DocumentContentKind
    }

    static func inspect(url: URL) -> Result {
        guard let document = PDFDocument(url: url) else { return .init(pageCount: 0, contentKind: .unknown) }
        let samples = (0..<min(document.pageCount, 16)).compactMap { document.page(at: $0)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) }
        let textPages = samples.filter { $0.count > 20 }.count
        let kind: DocumentContentKind
        if document.pageCount == 0 { kind = .unknown }
        else if textPages == 0 { kind = .scanned }
        else if textPages == samples.count { kind = .text }
        else { kind = .mixed }
        return .init(pageCount: document.pageCount, contentKind: kind)
    }
}
