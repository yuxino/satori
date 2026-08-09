import AppKit
import PDFKit
import Vision
import SatoriCore

/// Local, on-demand search for scanned or mixed PDFs.
///
/// PDFKit cannot search a page that has no text layer. A reader should not
/// have to abandon the reading flow just because a book is a scan, so this
/// service OCRs pages only after a normal PDF search misses. It keeps the
/// recognized text in a bounded in-memory cache; the original PDF and OCR
/// output are never written to disk.
enum ScannedPDFSearch {
    struct Result: Sendable {
        let pageIndex: Int
        let scannedPageCount: Int
        let pageCount: Int
        let wrapped: Bool
    }

    private actor TextCache {
        private let capacity = 180
        private var values: [String: String] = [:]
        private var order: [String] = []

        func value(for key: String) -> String? {
            values[key]
        }

        func insert(_ value: String, for key: String) {
            if values[key] == nil, values.count >= capacity, let oldest = order.first {
                values.removeValue(forKey: oldest)
                order.removeFirst()
            }
            values[key] = value
            order.removeAll { $0 == key }
            order.append(key)
        }
    }

    private static let cache = TextCache()

    /// Searches in reading order from the current page, then wraps once.
    /// OCR happens in a detached task so a long scan never freezes the reader.
    static func find(
        query: String,
        in url: URL,
        startingAt pageIndex: Int,
        direction: Int
    ) async -> Result? {
        let worker = Task.detached(priority: .userInitiated) {
            await findSynchronously(
                query: query,
                in: url,
                startingAt: pageIndex,
                direction: direction
            )
        }
        return await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private static func findSynchronously(
        query: String,
        in url: URL,
        startingAt pageIndex: Int,
        direction: Int
    ) async -> Result? {
        let normalizedQuery = compact(query)
        guard !normalizedQuery.isEmpty else { return nil }

        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess { url.stopAccessingSecurityScopedResource() }
        }

        guard let document = PDFDocument(url: url), document.pageCount > 0 else { return nil }
        let pageCount = document.pageCount
        // An out-of-range anchor is intentional: after the last hit, “next”
        // starts at pageCount and should wrap to page 0; likewise “previous”
        // from page 0 should begin at the final page rather than repeat page 0.
        let wrappedBeforeSearch = pageIndex < 0 || pageIndex >= pageCount
        let anchor = pageIndex < 0
            ? pageCount - 1
            : (pageIndex >= pageCount ? 0 : pageIndex)
        let isForward = direction >= 0
        let firstPass: [Int]
        let wrappedPass: [Int]
        if isForward {
            firstPass = Array(anchor..<pageCount)
            wrappedPass = Array(0..<anchor)
        } else {
            firstPass = Array(stride(from: anchor, through: 0, by: -1))
            wrappedPass = anchor == pageCount - 1
                ? []
                : Array(stride(from: pageCount - 1, through: anchor + 1, by: -1))
        }

        let fingerprint = fileFingerprint(for: url)
        var scanned = 0
        for (index, page) in (firstPass + wrappedPass).enumerated() {
            if Task.isCancelled { return nil }
            guard let pdfPage = document.page(at: page) else { continue }
            let key = fingerprint + "|" + String(page)
            let text: String
            if let cached = await cache.value(for: key) {
                text = cached
            } else {
                let native = ExtractedTextNormalizer.normalize(pdfPage.string ?? "")
                let recognized = native.isEmpty ? recognize(pdfPage) ?? "" : native
                text = recognized
                await cache.insert(recognized, for: key)
            }
            scanned += 1
            if compact(text).contains(normalizedQuery) {
                return Result(
                    pageIndex: page,
                    scannedPageCount: scanned,
                    pageCount: pageCount,
                    wrapped: wrappedBeforeSearch || index >= firstPass.count
                )
            }
        }
        return nil
    }

    private static func fileFingerprint(for url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let modification = values?.contentModificationDate?.timeIntervalSince1970 ?? -1
        let size = values?.fileSize ?? -1
        return url.standardizedFileURL.path + "|" + String(modification) + "|" + String(size)
    }

    private static func compact(_ text: String) -> String {
        ExtractedTextNormalizer.normalize(text)
            .lowercased()
            .filter { !$0.isWhitespace }
    }

    /// Search only needs enough OCR to locate a page. The learning answer
    /// path still uses its higher-resolution text/image evidence route.
    private static func recognize(_ page: PDFPage) -> String? {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let scale: CGFloat = 1_400 / max(bounds.width, bounds.height)
        let image = page.thumbnail(
            of: NSSize(width: bounds.width * scale, height: bounds.height * scale),
            for: .mediaBox
        )
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }

        let observations = request.results ?? []
        let lines = observations
            .sorted { lhs, rhs in
                let verticalDistance = lhs.boundingBox.midY - rhs.boundingBox.midY
                return abs(verticalDistance) > 0.02
                    ? verticalDistance > 0
                    : lhs.boundingBox.minX < rhs.boundingBox.minX
            }
            .compactMap { $0.topCandidates(1).first?.string }
        let normalized = ExtractedTextNormalizer.normalize(lines.joined(separator: "\n"))
        return normalized.isEmpty ? nil : normalized
    }
}
