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

        var cacheToken: String {
            switch self {
            case let .selection(text): "selection:\(text.hashValue)"
            case let .page(index): "page:\(index)"
            case let .pageRange(range): "range:\(range.lowerBound)-\(range.upperBound)"
            case .wholeDocument: "whole"
            case .none: "none"
            }
        }
    }

    /// 页面提取是阅读追问的本地前置步骤。PDFKit 每次重新打开 294 页的
    /// 文档会让用户误以为 Qwen 没响应；缓存已经提取的内容，让同一文档的
    /// 追问、验证和“接上文”直接进入模型请求。文件签名变化时自然换 key，
    /// 不会把替换后的 PDF 内容带进旧回答。
    private actor ContentCache {
        private var values: [String: LearningPageContent] = [:]
        private let capacity = 24

        func value(for key: String) -> LearningPageContent? {
            values[key]
        }

        func insert(_ value: LearningPageContent, for key: String) {
            if values.count >= capacity, values[key] == nil,
               let oldestKey = values.keys.first {
                values.removeValue(forKey: oldestKey)
            }
            values[key] = value
        }
    }

    private static let contentCache = ContentCache()

    /// 提取页面内容。配置了 Qwen 时，扫描页优先走 Qwen OCR；
    /// 未配置或 Qwen 失败时回退本地 Vision OCR，最后退回高清页图。
    static func extract(
        from url: URL,
        scope: Scope,
        qwenConfiguration: QwenConfiguration? = nil,
        anchorPage: Int? = nil
    ) async -> LearningPageContent? {
        switch scope {
        case let .selection(text):
            let cleaned = ExtractedTextNormalizer.normalize(text)
            guard !cleaned.isEmpty else { return nil }
            return .text(String(cleaned.prefix(24_000)))
        case .none:
            return nil
        case .page, .pageRange, .wholeDocument:
            let key = cacheKey(
                for: url,
                scope: scope,
                qwenConfiguration: qwenConfiguration,
                anchorPage: anchorPage
            )
            if let cached = await contentCache.value(for: key) {
                return cached
            }

            let extracted: LearningPageContent?
            switch scope {
            case let .page(pageIndex):
                extracted = await extractPage(from: url, pageIndex: pageIndex, qwenConfiguration: qwenConfiguration)
            case let .pageRange(range):
                extracted = await extractPageRange(from: url, range: range, qwenConfiguration: qwenConfiguration)
            case .wholeDocument:
                extracted = await extractWholeDocument(from: url, anchorPage: anchorPage)
            case .selection, .none:
                extracted = nil
            }
            if let extracted {
                await contentCache.insert(extracted, for: key)
            }
            return extracted
        }
    }

    private static func cacheKey(
        for url: URL,
        scope: Scope,
        qwenConfiguration: QwenConfiguration?,
        anchorPage: Int?
    ) -> String {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let modification = values?.contentModificationDate?.timeIntervalSince1970 ?? -1
        let size = values?.fileSize ?? -1
        let model = qwenConfiguration?.modelID ?? "local"
        let anchor = anchorPage.map(String.init) ?? "none"
        return "\(url.standardizedFileURL.path)|\(modification)|\(size)|\(scope.cacheToken)|\(anchor)|\(model)"
    }

    /// 多页范围：并发取各页文字层，扫描页按需 Qwen OCR / 本地 Vision，
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
        let clampedEnd = min(range.upperBound, document.pageCount - 1)
        guard range.lowerBound <= clampedEnd else { return nil }

        // 扫描页 OCR 是最大的耗时点，4 路并发显著加快整章/多页理解。
        let pages = await extractPagesConcurrently(
            document: document,
            indices: Array(range.lowerBound...clampedEnd),
            qwenConfiguration: qwenConfiguration,
            useQwenOCR: true,
            ocrBudget: nil,
            concurrency: 4
        )

        var assembled = ""
        for (pageIndex, text) in pages {
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
            // 带页码标注返回，和整章/多页提取的格式一致，模型能明确知道是哪一页。
            return .text("【第 \(pageIndex + 1) 页】\n" + String(text.prefix(24_000)))
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

    private static func extractWholeDocument(from url: URL, anchorPage: Int?) async -> LearningPageContent? {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess { url.stopAccessingSecurityScopedResource() }
        }

        guard let document = PDFDocument(url: url), document.pageCount > 0 else { return nil }

        let limit = 60_000
        let nearbyPages: [Int] = {
            guard let anchorPage else { return [] }
            let clamped = min(max(anchorPage, 0), document.pageCount - 1)
            let start = max(0, clamped - 2)
            let end = min(document.pageCount - 1, clamped + 2)
            return Array(start...end)
        }()
        let nearbySet = Set(nearbyPages)
        let allPages = Array(0..<document.pageCount)
        // 整本书也必须先保证当前阅读位置附近在上下文里；否则前 6 万字符
        // 会被书的开头吃完，用户在第 188 页提问时却拿不到眼前内容。
        // 同时把附近页排到 OCR 队列前面，扫描版也优先识别当前页。
        let extractionOrder = nearbyPages + allPages.filter { !nearbySet.contains($0) }
        let pages = await extractPagesConcurrently(
            document: document,
            indices: extractionOrder,
            qwenConfiguration: nil,
            useQwenOCR: false,
            ocrBudget: OCRBudget(40),
            concurrency: 3
        )

        let orderedPages = nearbyPages.compactMap { index in
            pages.first { $0.pageIndex == index }
        } + pages.filter { !nearbySet.contains($0.pageIndex) }

        var assembled = nearbyPages.isEmpty ? "" : "【当前阅读位置附近】\n"
        for (pageIndex, text) in orderedPages {
            guard !text.isEmpty else { continue }
            assembled += "【第 \(pageIndex + 1) 页】\n\(text)\n\n"
            if assembled.count >= limit { break }
        }

        let trimmed = assembled.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return .text(String(trimmed.prefix(limit)))
    }

    // MARK: - 并发提取

    /// 有界并发地提取一批页面的文字（结果按页序返回）。
    /// 扫描页的 OCR（网络调用或本地 Vision）是主要耗时点，并行处理后
    /// 整章/整本书提取大幅提速。`useQwenOCR` 控制是否走 Qwen OCR；
    /// `ocrBudget` 限制整本书场景里做 OCR 的页数上限（nil 表示不限）。
    private static func extractPagesConcurrently(
        document: PDFDocument,
        indices: [Int],
        qwenConfiguration: QwenConfiguration?,
        useQwenOCR: Bool,
        ocrBudget: OCRBudget?,
        concurrency: Int
    ) async -> [(pageIndex: Int, text: String)] {
        var results: [(pageIndex: Int, text: String)] = []
        results.reserveCapacity(indices.count)
        let documentBox = PDFDocumentBox(document: document)

        await withTaskGroup(of: (Int, String).self) { group in
            var iterator = indices.makeIterator()
            // 先填满并发窗口，之后每完成一个就补一个。
            for _ in 0..<min(concurrency, indices.count) {
                if let pageIndex = iterator.next() {
                    group.addTask {
                        let text = await Self.extractPageText(
                            document: documentBox.document,
                            pageIndex: pageIndex,
                            qwenConfiguration: qwenConfiguration,
                            useQwenOCR: useQwenOCR,
                            ocrBudget: ocrBudget
                        )
                        return (pageIndex, text)
                    }
                }
            }
            while let result = await group.next() {
                results.append(result)
                if let next = iterator.next() {
                    group.addTask {
                        let text = await Self.extractPageText(
                            document: documentBox.document,
                            pageIndex: next,
                            qwenConfiguration: qwenConfiguration,
                            useQwenOCR: useQwenOCR,
                            ocrBudget: ocrBudget
                        )
                        return (next, text)
                    }
                }
            }
        }
        return results.sorted { $0.pageIndex < $1.pageIndex }
    }

    /// 提取单页文字：优先文字层；不足时按配置走 Qwen OCR / 本地 Vision。
    /// OCR 预算（整本书场景）耗尽后不再识别，保持原有行为。
    private static func extractPageText(
        document: PDFDocument,
        pageIndex: Int,
        qwenConfiguration: QwenConfiguration?,
        useQwenOCR: Bool,
        ocrBudget: OCRBudget?
    ) async -> String {
        guard let page = document.page(at: pageIndex) else { return "" }
        var text = ExtractedTextNormalizer.normalize(page.string ?? "")
        guard text.count < 40, (await ocrBudget?.take()) ?? true else { return text }

        if useQwenOCR, let qwenConfiguration,
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
        return text
    }
}

/// PDFDocument 不是 Sendable，但这里只做只读的逐页文字提取，
/// 用盒子包装以允许并发访问。
private final class PDFDocumentBox: @unchecked Sendable {
    let document: PDFDocument

    init(document: PDFDocument) {
        self.document = document
    }
}

/// 整本书场景的 OCR 页数预算：多路并发下原子扣减。
private actor OCRBudget {
    private var remaining: Int

    init(_ remaining: Int) {
        self.remaining = remaining
    }

    /// 还有预算则扣 1 并返回 true；否则返回 false。
    func take() -> Bool {
        guard remaining > 0 else { return false }
        remaining -= 1
        return true
    }
}
