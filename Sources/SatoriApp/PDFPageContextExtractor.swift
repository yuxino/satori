import AppKit
import PDFKit
import Vision
import SatoriCore

enum PDFPageContextExtractor {
    /// What slice of the PDF a question should be grounded in.
    enum Scope: Equatable {
        /// Text the reader highlighted on the page.
        case selection(String)
        /// The page currently on screen.
        case page(Int)
        /// 连续多页（0 起、含两端）：逐页提取并拼接，扫描页走 OCR。
        case pageRange(ClosedRange<Int>)
        /// The whole book, as concatenated page text.
        case wholeDocument
        /// 不带任何页上下文。
        case none
    }

    /// 提取页面内容。配置了 Qwen 时，扫描页优先走 Qwen OCR；
    /// 未配置或 Qwen 失败时回退本地 Vision OCR，最后退回高清页图。
    static func extract(
        from url: URL,
        scope: Scope,
        qwenConfiguration: QwenConfiguration? = nil
    ) async -> LearningPageContent? {
        switch scope {
        case let .selection(text):
            let cleaned = ExtractedTextNormalizer.normalize(text)
            guard !cleaned.isEmpty else { return nil }
            return .text(String(cleaned.prefix(24_000)))
        case let .page(pageIndex):
            return await extractPage(from: url, pageIndex: pageIndex, qwenConfiguration: qwenConfiguration)
        case let .pageRange(range):
            return await extractPageRange(from: url, range: range, qwenConfiguration: qwenConfiguration)
        case .wholeDocument:
            return extractWholeDocument(from: url)
        case .none:
            return nil
        }
    }

    /// 多页范围：逐页取文字层，扫描页按需 Qwen OCR / 本地 Vision，
    /// 带【第 N 页】标记拼接成一整段。纯图片页没有可识别文字时跳过。
    private static func extractPageRange(
        from url: URL,
        range: ClosedRange<Int>,
        qwenConfiguration: QwenConfiguration?
    ) async -> LearningPageContent? {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess { url.stopAccessingSecurityScopedResource() }
        }

        guard let document = PDFDocument(url: url),
              document.pageCount > 0 else { return nil }

        let limit = 60_000
        var assembled = ""
        let clampedEnd = min(range.upperBound, document.pageCount - 1)
        guard range.lowerBound <= clampedEnd else { return nil }

        for pageIndex in range.lowerBound...clampedEnd {
            guard let page = document.page(at: pageIndex) else { continue }
            var text = ExtractedTextNormalizer.normalize(page.string ?? "")
            if text.count < 40,
               let qwenConfiguration,
               let image = renderPageImage(page, maximumLongestSide: Self.ocrRenderLongestSide),
               let jpeg = jpegData(from: image),
               let recognized = await QwenOCRService.recognizeText(in: jpeg, configuration: qwenConfiguration),
               recognized.count >= 40 {
                text = ExtractedTextNormalizer.normalize(recognized)
            }
            if text.count < 40,
               let image = renderPageImage(page, maximumLongestSide: Self.ocrRenderLongestSide),
               let recognized = recognizeText(in: image),
               recognized.count >= 40 {
                text = recognized
            }
            guard !text.isEmpty else { continue }
            assembled += "【第 \(pageIndex + 1) 页】\n\(text)\n\n"
            if assembled.count >= limit { break }
        }

        let trimmed = assembled.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return .text(String(trimmed.prefix(limit)))
    }

    private static func extractPage(
        from url: URL,
        pageIndex: Int,
        qwenConfiguration: QwenConfiguration?
    ) async -> LearningPageContent? {
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

        // 扫描版 / 图片页：先 Qwen OCR（识别质量更好），失败再本地 Vision，
        // 都识别不出就退回高清页图，让模型直接看图。
        guard let image = renderPageImage(page, maximumLongestSide: Self.ocrRenderLongestSide) else { return nil }
        if let qwenConfiguration,
           let jpeg = jpegData(from: image),
           let recognized = await QwenOCRService.recognizeText(in: jpeg, configuration: qwenConfiguration),
           recognized.count >= 40 {
            return .text(String(recognized.prefix(24_000)))
        }
        if let recognized = recognizeText(in: image),
           recognized.count >= 40 {
            return .text(String(recognized.prefix(24_000)))
        }

        // OCR 也没读到内容（纯图/公式页）：退回高清页图，让模型看图。
        guard let jpeg = renderPageJPEG(page) else { return nil }
        return .imageJPEG(jpeg)
    }

    /// OCR 用页图的最长边。太小的图文字发虚，识别率低；约 1800px
    /// 在清晰度和处理耗时之间平衡（单页识别约 0.2–0.8s）。
    private static let ocrRenderLongestSide: CGFloat = 1_800
    /// 退回图片路径时页图的最长边（约 200–500KB/页）。
    private static let imageRenderLongestSide: CGFloat = 1_600
    private static let jpegCompression: CGFloat = 0.85

    private static func renderPageImage(_ page: PDFPage, maximumLongestSide: CGFloat) -> NSImage? {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = maximumLongestSide / max(bounds.width, bounds.height)
        let size = NSSize(width: bounds.width * scale, height: bounds.height * scale)
        return page.thumbnail(of: size, for: .mediaBox)
    }

    private static func renderPageJPEG(_ page: PDFPage) -> Data? {
        guard let image = renderPageImage(page, maximumLongestSide: Self.imageRenderLongestSide) else { return nil }
        return jpegData(from: image)
    }

    private static func jpegData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: Self.jpegCompression])
    }

    /// 本地 OCR（Vision）：简体中文优先、英文兜底，结果按阅读顺序
    /// （从上到下、从左到右）排列。识别失败或没有文字时返回 nil。
    private static func recognizeText(in image: NSImage) -> String? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        // Vision 的 boundingBox 原点在左下角：先按行（y 中心从高到低），
        // 同行内再按 x 从左到右，还原真实的阅读顺序。
        let observations = (request.results ?? []).sorted { lhs, rhs in
            let dy = lhs.boundingBox.midY - rhs.boundingBox.midY
            if abs(dy) > 0.02 { return dy > 0 }
            return lhs.boundingBox.minX < rhs.boundingBox.minX
        }
        let text = observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        let normalized = ExtractedTextNormalizer.normalize(text)
        return normalized.isEmpty ? nil : normalized
    }

    private static func extractWholeDocument(from url: URL) -> LearningPageContent? {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess { url.stopAccessingSecurityScopedResource() }
        }

        guard let document = PDFDocument(url: url), document.pageCount > 0 else { return nil }

        var assembled = ""
        let limit = 60_000
        // 扫描版全书 OCR 很耗时，最多识别前 40 页就够撑满上下文；
        // 有文字层的页不 OCR。
        let maxOCRPages = 40
        var ocrPages = 0
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            var text = ExtractedTextNormalizer.normalize(page.string ?? "")
            if text.count < 40, ocrPages < maxOCRPages,
               let image = renderPageImage(page, maximumLongestSide: Self.ocrRenderLongestSide),
               let recognized = recognizeText(in: image) {
                ocrPages += 1
                text = recognized
            }
            guard !text.isEmpty else { continue }
            assembled += "【第 \(pageIndex + 1) 页】\n\(text)\n\n"
            if assembled.count >= limit { break }
        }

        let trimmed = assembled.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return .text(String(trimmed.prefix(limit)))
    }
}
