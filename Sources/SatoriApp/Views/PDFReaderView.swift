import AppKit
import PDFKit
import SwiftUI
import SatoriCore

/// Notification posted by the selection toolbar's reading actions. The
/// learning panel consumes it via ContentView → ReaderSelectionRouter and
/// immediately starts the selected intent. userInfo: text, pageIndex, url,
/// intent.
extension Notification.Name {
    static let satoriAskSelectionRequested = Notification.Name("satori.askSelectionRequested")
    static let satoriRunSelectionRequested = Notification.Name("satori.runSelectionRequested")
    /// userInfo: documentID, url, pageIndex, jpegData (a cropped page region).
    static let satoriPageRegionCaptured = Notification.Name("satori.pageRegionCaptured")
    /// userInfo: documentID, url (the PDF), position (ReadingPosition with page + offset).
    static let satoriReaderJumpRequested = Notification.Name("satori.readerJumpRequested")
}

/// The reading canvas. Text selection raises a floating「理解 / 接上文 / 举例 /
/// 试试看 / 复制」
/// toolbar (AppKit overlay, theme-colored); the page's visible position is
/// reported as a real 0…1 offset instead of a constant 0, and jumps can be
/// targeted at a (page, offset) pair via the satoriReaderJumpRequested channel.
struct PDFReaderView: NSViewRepresentable {
    let documentID: UUID
    let url: URL
    let initialPosition: ReadingPosition
    @Binding var currentPageIndex: Int
    @Binding var isRegionCaptureEnabled: Bool
    let onPositionChanged: (Int, Double) -> Void
    var onPageRegionCaptured: ((Data, Int) -> Void)? = nil

    /// Selection toolbar callbacks, in addition to the notification channel:
    /// (selectedText, pageIndex). Defaults keep existing call sites working.
    var onAskSelection: ((String, Int) -> Void)? = nil
    var onRunSelection: ((String, Int) -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(
            documentID: documentID,
            currentPageIndex: $currentPageIndex,
            onPageRegionCaptured: onPageRegionCaptured,
            onPositionChanged: onPositionChanged,
            onAskSelection: onAskSelection,
            onRunSelection: onRunSelection
        )
    }

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = .underPageBackgroundColor
        view.pageShadowsEnabled = true
        view.document = PDFDocument(url: url)
        if let document = view.document, document.pageCount > 0 {
            let pageIndex = min(max(initialPosition.pageIndex, 0), document.pageCount - 1)
            if initialPosition.normalizedPageOffset > 0 {
                // 创建时 PDFView 还没完成布局（frame 为零、缩放比例未定），
                // 立刻 go(to:) 会按错误的缩放放置目的地，恢复位置因此有偏差。
                // 等布局完成后再跳（见 restoreInitialPosition）。
                context.coordinator.pendingInitialRestore = ReadingPosition(
                    pageIndex: pageIndex,
                    normalizedPageOffset: initialPosition.normalizedPageOffset
                )
            } else if let page = document.page(at: pageIndex) {
                view.go(to: page)
            }
        }
        context.coordinator.observe(view)
        context.coordinator.setRegionCaptureEnabled(isRegionCaptureEnabled, in: view)
        context.coordinator.restoreInitialPosition(in: view)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        context.coordinator.onAskSelection = onAskSelection
        context.coordinator.onRunSelection = onRunSelection
        context.coordinator.onPageRegionCaptured = onPageRegionCaptured
        context.coordinator.setRegionCaptureEnabled(isRegionCaptureEnabled, in: view)
        guard let document = view.document, document.pageCount > 0 else { return }
        let targetIndex = min(max(currentPageIndex, 0), document.pageCount - 1)
        let visibleIndex = view.currentPage.map(document.index(for:))
        guard visibleIndex != targetIndex else { return }
        // 初始恢复还没落地（等布局完成），这里绑定驱动的跳转会覆盖掉偏移，
        // 先跳过，统一由 restoreInitialPosition 处理。
        if context.coordinator.pendingInitialRestore != nil { return }
        if let jump = context.coordinator.consumePendingJump(), jump.pageIndex == targetIndex {
            context.coordinator.jump(to: jump, in: view)
        } else if let page = document.page(at: targetIndex) {
            view.go(to: page)
        }
    }

    static func dismantleNSView(_ view: PDFView, coordinator: Coordinator) {
        coordinator.stopObserving()
    }

    @MainActor
    final class Coordinator: NSObject {
        private let documentID: UUID
        private weak var observedView: PDFView?
        private let currentPageIndex: Binding<Int>
        private let onPositionChanged: (Int, Double) -> Void
        var onPageRegionCaptured: ((Data, Int) -> Void)?
        var onAskSelection: ((String, Int) -> Void)?
        var onRunSelection: ((String, Int) -> Void)?

        /// The text selected when the toolbar was last shown. Actions use this
        /// so a button click that clears the live selection still acts on what
        /// the reader highlighted.
        private var pinnedSelection = ""
        private var toolbar: SelectionToolbarView?
        /// 主题化选中高亮的覆盖层（PDFKit 不支持直接改内置选区颜色，
        /// 用一层薰衣草半透明视图叠在系统蓝色选区上）。
        private var selectionOverlayViews: [NSView] = []
        /// A jump requested through the notification channel but not yet
        /// applied by a binding-driven page change.
        private var pendingJump: ReadingPosition?
        /// 打开文档时待恢复的阅读位置：等 PDFView 完成首次布局后再落地，
        /// 避免按错误的缩放比例放置目的地。
        var pendingInitialRestore: ReadingPosition?
        /// Scrolling reports offsets continuously; only the settle matters.
        private var offsetDebounce: Timer?
        private var jumpObserverToken: NSObjectProtocol?
        /// 最近一次上报的 (页, 偏移)，用于滤掉同一位置导航触发的重复上报。
        private var lastReportedPageIndex: Int?
        private var lastReportedOffset: Double = -1
        private var regionCaptureView: RegionCaptureView?

        init(
            documentID: UUID,
            currentPageIndex: Binding<Int>,
            onPageRegionCaptured: ((Data, Int) -> Void)?,
            onPositionChanged: @escaping (Int, Double) -> Void,
            onAskSelection: ((String, Int) -> Void)?,
            onRunSelection: ((String, Int) -> Void)?
        ) {
            self.documentID = documentID
            self.currentPageIndex = currentPageIndex
            self.onPageRegionCaptured = onPageRegionCaptured
            self.onPositionChanged = onPositionChanged
            self.onAskSelection = onAskSelection
            self.onRunSelection = onRunSelection
        }

        func observe(_ view: PDFView) {
            observedView = view
            let center = NotificationCenter.default
            center.addObserver(self, selector: #selector(pageChanged), name: .PDFViewPageChanged, object: view)
            center.addObserver(self, selector: #selector(selectionChanged), name: .PDFViewSelectionChanged, object: view)
            center.addObserver(self, selector: #selector(viewportChanged), name: .PDFViewVisiblePagesChanged, object: view)
            // PDFView's embedded scroll view carries in-page scrolling (offset
            // changes within a tall page); the visible-pages notification only
            // fires at page boundaries.
            if let scrollView = view.subviews.compactMap({ $0 as? NSScrollView }).first {
                center.addObserver(self, selector: #selector(viewportChanged), name: NSScrollView.didLiveScrollNotification, object: scrollView)
                center.addObserver(self, selector: #selector(viewportChanged), name: NSScrollView.didEndLiveScrollNotification, object: scrollView)
            }
            jumpObserverToken = center.addObserver(
                forName: .satoriReaderJumpRequested,
                object: nil,
                queue: .main
            ) { [weak self] note in
                // Extract Sendable payloads before crossing isolation; the
                // Notification itself is not Sendable.
                let position = note.userInfo?["position"] as? ReadingPosition
                let requestedDocumentID = note.userInfo?["documentID"] as? UUID
                let requestedURL = note.userInfo?["url"] as? URL
                let selectionText = note.userInfo?["selectionText"] as? String
                let selectionOffsetIsExact = note.userInfo?["selectionOffsetIsExact"] as? Bool ?? false
                Task { @MainActor [weak self] in
                    self?.handleJumpRequest(
                        position: position,
                        requestedDocumentID: requestedDocumentID,
                        requestedURL: requestedURL,
                        selectionText: selectionText,
                        selectionOffsetIsExact: selectionOffsetIsExact
                    )
                }
            }
        }

        func stopObserving() {
            NotificationCenter.default.removeObserver(self)
            if let jumpObserverToken {
                NotificationCenter.default.removeObserver(jumpObserverToken)
                self.jumpObserverToken = nil
            }
            offsetDebounce?.invalidate()
            offsetDebounce = nil
            regionCaptureView?.removeFromSuperview()
            regionCaptureView = nil
            toolbar?.removeFromSuperview()
            toolbar = nil
            observedView = nil
        }

        /// Scanned PDFs have no PDFKit text selection. A temporary drag layer
        /// lets the reader isolate a diagram/code/formula region without
        /// leaving Satori to take a separate screenshot and paste it back.
        func setRegionCaptureEnabled(_ enabled: Bool, in view: PDFView) {
            if enabled {
                if regionCaptureView?.superview !== view {
                    regionCaptureView?.removeFromSuperview()
                    let capture = RegionCaptureView(frame: view.bounds)
                    capture.autoresizingMask = [.width, .height]
                    capture.onComplete = { [weak self, weak view] rect in
                        guard let self, let view else { return }
                        self.captureRegion(rect, in: view)
                    }
                    capture.onCancel = { [weak self] in
                        self?.regionCaptureView?.removeFromSuperview()
                        self?.regionCaptureView = nil
                    }
                    view.addSubview(capture)
                    regionCaptureView = capture
                }
            } else if let regionCaptureView {
                regionCaptureView.removeFromSuperview()
                self.regionCaptureView = nil
            }
        }

        private func captureRegion(_ viewRect: NSRect, in view: PDFView) {
            defer {
                regionCaptureView?.removeFromSuperview()
                regionCaptureView = nil
            }
            guard let document = view.document,
                  let page = view.currentPage else { return }
            let pageRectInView = view.convert(page.bounds(for: .mediaBox), from: page)
            let clipped = viewRect.intersection(pageRectInView)
            guard clipped.width >= 24, clipped.height >= 24 else { return }
            let pageRect = view.convert(clipped, to: page)
            guard let jpeg = Self.renderRegionJPEG(page: page, rect: pageRect) else { return }
            let pageIndex = document.index(for: page)
            guard pageIndex >= 0 else { return }
            onPageRegionCaptured?(jpeg, pageIndex)
        }

        private static func renderRegionJPEG(page: PDFPage, rect: NSRect) -> Data? {
            let bounds = page.bounds(for: .mediaBox).standardized
            let clipped = rect.standardized.intersection(bounds)
            guard clipped.width >= 1, clipped.height >= 1,
                  bounds.width > 0, bounds.height > 0 else { return nil }

            let longestSide: CGFloat = 2_200
            let scale = longestSide / max(bounds.width, bounds.height)
            let fullSize = NSSize(width: bounds.width * scale, height: bounds.height * scale)
            let image = page.thumbnail(of: fullSize, for: .mediaBox)
            var proposedRect = NSRect(origin: .zero, size: image.size)
            guard let fullImage = image.cgImage(
                forProposedRect: &proposedRect,
                context: nil,
                hints: nil
            ) else { return nil }

            let imageBounds = CGRect(
                x: 0,
                y: 0,
                width: CGFloat(fullImage.width),
                height: CGFloat(fullImage.height)
            )
            let cropRect = CGRect(
                x: (clipped.minX - bounds.minX) / bounds.width * imageBounds.width,
                y: (bounds.maxY - clipped.maxY) / bounds.height * imageBounds.height,
                width: clipped.width / bounds.width * imageBounds.width,
                height: clipped.height / bounds.height * imageBounds.height
            ).integral.intersection(imageBounds)
            guard cropRect.width >= 2, cropRect.height >= 2,
                  let cropped = fullImage.cropping(to: cropRect) else { return nil }
            let bitmap = NSBitmapImageRep(cgImage: cropped)
            return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.86])
        }

        func consumePendingJump() -> ReadingPosition? {
            defer { pendingJump = nil }
            return pendingJump
        }

        // MARK: Page position

        @MainActor @objc private func pageChanged() {
            guard let view = observedView, let document = view.document, let page = view.currentPage else { return }
            let pageIndex = document.index(for: page)
            currentPageIndex.wrappedValue = pageIndex
            reportPosition(in: view, pageIndex: pageIndex)
        }

        /// Fires on scroll/zoom too; debounce so a long scroll within a tall
        /// page still lands a real offset without spamming saves.
        @MainActor @objc private func viewportChanged() {
            guard let view = observedView, let page = view.currentPage else { return }
            let pageIndex = view.document?.index(for: page) ?? currentPageIndex.wrappedValue
            offsetDebounce?.invalidate()
            offsetDebounce = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let observed = self.observedView else { return }
                    self.reportPosition(in: observed, pageIndex: pageIndex)
                    self.settleToolbar(in: observed)
                }
            }
        }

        @MainActor private func reportPosition(in view: PDFView, pageIndex: Int) {
            let offset = visibleOffset(in: view)
            // 一次翻页会先后触发 PDFViewPageChanged 与滚动/可见页通知；偏移未变时
            // 跳过，避免重复写盘和重复记录「已读页」。
            if pageIndex == lastReportedPageIndex, abs(offset - lastReportedOffset) < 0.001 { return }
            lastReportedPageIndex = pageIndex
            lastReportedOffset = offset
            onPositionChanged(pageIndex, offset)
        }

        /// 浮动工具条挂在 PDFView 的静态坐标空间里，滚动时不会跟着选择走，
        /// PDFKit 也不会为滚动重发 SelectionChanged。滚动停下后把工具条重新
        /// 贴回选择上；选择已消失或不在当前页时把它收掉。
        @MainActor private func settleToolbar(in view: PDFView) {
            guard toolbar?.superview != nil else { return }
            let selection = view.currentSelection
            let text = selection?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let page = selection?.pages.first
            let isOnCurrentPage: Bool
            if let page, let document = view.document, let currentPage = view.currentPage {
                isOnCurrentPage = document.index(for: page) == document.index(for: currentPage)
            } else {
                isOnCurrentPage = false
            }
            guard let selection, !text.isEmpty, isOnCurrentPage else {
                hideToolbar()
                removeSelectionOverlay()
                return
            }
            showToolbar(for: selection, in: view)
            updateSelectionOverlay(in: view)
        }

        /// 在选区上叠一层主题色高亮。PDFKit 在 macOS 上把用户选区画成系统蓝，
        /// 且 `PDFSelection.color` 只影响手动绘制；这里按选区的行边界生成
        /// 薰衣草覆盖层，让选中效果跟上主题。
        @MainActor private func updateSelectionOverlay(in view: PDFView) {
            removeSelectionOverlay()
            guard let selection = view.currentSelection,
                  !(selection.string?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true),
                  let page = selection.pages.first,
                  let document = view.document,
                  let currentPage = view.currentPage,
                  document.index(for: page) == document.index(for: currentPage) else { return }
            for line in selection.selectionsByLine() {
                guard let linePage = line.pages.first else { continue }
                let rect = view.convert(line.bounds(for: linePage), from: linePage)
                    .insetBy(dx: -1, dy: -1)
                guard rect.intersects(view.visibleRect) else { continue }
                let overlay = SelectionHighlightView(frame: rect)
                selectionOverlayViews.append(overlay)
                view.addSubview(overlay)
            }
        }

        @MainActor private func removeSelectionOverlay() {
            for overlay in selectionOverlayViews {
                overlay.removeFromSuperview()
            }
            selectionOverlayViews.removeAll()
        }

        /// How far the current page has scrolled past the top of the viewport,
        /// normalized to 0…1. 0 = page top at viewport top; 1 = page bottom at
        /// viewport top. PDFView is non-flipped, so y grows upward.
        private func visibleOffset(in view: PDFView) -> Double {
            guard let page = view.currentPage else { return 0 }
            return visibleOffset(in: view, page: page)
        }

        private func visibleOffset(in view: PDFView, page: PDFPage) -> Double {
            let pageRect = view.convert(page.bounds(for: .mediaBox), from: page)
            let viewport = view.visibleRect
            let pageHeight = max(pageRect.height, 1)
            let scrolledPast = pageRect.maxY - viewport.maxY
            return min(max(scrolledPast / pageHeight, 0), 1)
        }

        // MARK: Offset-aware jumps

        @MainActor private func handleJumpRequest(
            position: ReadingPosition?,
            requestedDocumentID: UUID?,
            requestedURL: URL?,
            selectionText: String?,
            selectionOffsetIsExact: Bool
        ) {
            guard let position, let view = observedView else { return }
            if let requestedDocumentID, requestedDocumentID != documentID {
                return // Another document's jump; ignore.
            }
            if let requestedURL, let documentURL = view.document?.documentURL,
               requestedURL.standardizedFileURL != documentURL.standardizedFileURL {
                return // Another document's jump; ignore.
            }
            pendingJump = position
            jump(to: position, in: view)
            if let selectionText {
                // PDFDestination 只负责把视口送到附近；下一帧再用 PDFKit 的文本
                // 搜索恢复真正的选区，让“回到原文”不再要求用户二次寻找句子。
                DispatchQueue.main.async { [weak self, weak view] in
                    guard let self, let view else { return }
                    self.restoreSelection(
                        selectionText,
                        pageIndex: position.pageIndex,
                        normalizedOffset: position.normalizedPageOffset,
                        offsetIsExact: selectionOffsetIsExact,
                        in: view
                    )
                }
            }
        }

        @MainActor private func restoreSelection(
            _ text: String,
            pageIndex: Int,
            normalizedOffset: Double?,
            offsetIsExact: Bool,
            in view: PDFView
        ) {
            guard let document = view.document else { return }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let firstLine = trimmed.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).first.map(String.init) ?? trimmed
            let queries = [trimmed, firstLine, String(firstLine.prefix(120))]
            var matches: [PDFSelection] = []
            for query in queries where !query.isEmpty {
                for match in document.findString(query, withOptions: [.literal])
                    where match.pages.contains(where: { document.index(for: $0) == pageIndex }) {
                    // The full selection and its first-line fallback can find
                    // the same occurrence. Keep one candidate per geometry so
                    // the offset comparison below is deterministic.
                    let isDuplicate = matches.contains { existing in
                        guard let existingPage = existing.pages.first,
                              let matchPage = match.pages.first,
                              document.index(for: existingPage) == document.index(for: matchPage)
                        else { return false }
                        let existingBounds = existing.bounds(for: existingPage)
                        let matchBounds = match.bounds(for: matchPage)
                        return existingBounds.insetBy(dx: -0.5, dy: -0.5).intersects(matchBounds)
                    }
                    if !isDuplicate { matches.append(match) }
                }
            }
            guard !matches.isEmpty else { return }

            // A page can contain the same short phrase several times. The
            // saved offset is the selected passage's vertical position, so use
            // it to choose the nearest occurrence instead of the first match.
            let selection = matches.min { lhs, rhs in
                guard offsetIsExact,
                      let expected = normalizedOffset,
                      let lhsPage = lhs.pages.first,
                      let rhsPage = rhs.pages.first else { return false }
                return abs(selectionOffset(lhs, on: lhsPage) - expected)
                    < abs(selectionOffset(rhs, on: rhsPage) - expected)
            } ?? matches[0]
            view.setCurrentSelection(selection, animate: true)
            view.scrollSelectionToVisible(nil)
        }

        /// Offset of a selection's vertical center from the top of its page.
        /// It deliberately shares ReadingPosition's 0…1 convention: 0 is the
        /// page top and 1 is the page bottom.
        private func selectionOffset(_ selection: PDFSelection, on page: PDFPage) -> Double {
            let bounds = page.bounds(for: .mediaBox)
            let selectedBounds = selection.bounds(for: page)
            guard bounds.height > 0 else { return 0 }
            let fromTop = bounds.maxY - selectedBounds.midY
            return min(max(fromTop / bounds.height, 0), 1)
        }

        /// Positions the viewport so the page's `normalizedPageOffset` sits at
        /// the top of the view (offset 0 = page top, 1 = page bottom).
        @MainActor func jump(to position: ReadingPosition, in view: PDFView) {
            guard let document = view.document, let page = document.page(at: position.pageIndex) else { return }
            if position.normalizedPageOffset > 0 {
                let bounds = page.bounds(for: .mediaBox)
                let y = bounds.maxY - position.normalizedPageOffset * bounds.height
                view.go(to: PDFDestination(page: page, at: CGPoint(x: bounds.midX, y: y)))
            } else {
                view.go(to: page)
            }
        }

        /// 打开文档时恢复上次阅读位置。PDFView 首次创建时 frame 还是零、
        /// autoScales 的缩放比例未定，立刻跳转会按错误的缩放放置目的地；
        /// 这里等到视图进入窗口、完成布局后再落地。
        @MainActor func restoreInitialPosition(in view: PDFView) {
            guard let position = pendingInitialRestore else { return }
            guard view.window != nil, view.bounds.width > 0, view.bounds.height > 0 else {
                DispatchQueue.main.async { [weak self] in
                    guard let self, let observed = self.observedView else { return }
                    Task { @MainActor in
                        self.restoreInitialPosition(in: observed)
                    }
                }
                return
            }
            pendingInitialRestore = nil
            jump(to: position, in: view)
        }

        // MARK: Selection toolbar

        @MainActor @objc private func selectionChanged() {
            guard let view = observedView else { return }
            let selection = view.currentSelection
            let text = selection?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if text.isEmpty {
                hideToolbar()
                removeSelectionOverlay()
            } else {
                pinnedSelection = text
                showToolbar(for: selection, in: view)
                updateSelectionOverlay(in: view)
            }
        }

        @MainActor private func showToolbar(for selection: PDFSelection?, in view: PDFView) {
            guard let selection, let page = selection.pages.first else {
                hideToolbar()
                return
            }

            let bar = toolbar ?? makeToolbar()
            let isNewlyShown = bar.superview !== view
            if isNewlyShown {
                bar.removeFromSuperview()
                view.addSubview(bar)
            }
            bar.layoutSubtreeIfNeeded()
            let size = bar.fittingSize

            // Prefer anchoring just above the selection: the line above was
            // already read, so the bar covers nothing the user is about to
            // read. Fall back to below only when the selection sits too close
            // to the page top to fit above. PDFView's subview space is
            // non-flipped (y grows upward).
            let bounds = selection.bounds(for: page)
            let gap: CGFloat = 12
            let selectionTopInView = view.convert(NSPoint(x: bounds.minX, y: bounds.maxY), from: page).y
            let selectionBottomInView = view.convert(NSPoint(x: bounds.minX, y: bounds.minY), from: page).y
            let leftInView = view.convert(NSPoint(x: bounds.minX, y: bounds.minY), from: page).x

            let belowOriginY = selectionBottomInView - gap - size.height
            let aboveOriginY = selectionTopInView + gap
            let fitsAbove = aboveOriginY + size.height <= view.bounds.height - gap
            let originY: CGFloat = fitsAbove ? aboveOriginY : belowOriginY

            var origin = NSPoint(x: leftInView, y: originY)
            origin.x = min(max(origin.x, gap), max(gap, view.bounds.width - size.width - gap))
            origin.y = min(max(origin.y, gap), max(gap, view.bounds.height - size.height - gap))
            bar.frame = NSRect(origin: origin, size: size)
            if isNewlyShown { bar.playAppearance() }
        }

        @MainActor private func makeToolbar() -> SelectionToolbarView {
            let bar = SelectionToolbarView()
            bar.onExplain = { [weak self] in
                self?.deliverSelection(intent: .explain)
            }
            bar.onContext = { [weak self] in
                self?.deliverSelection(intent: .context)
            }
            bar.onExample = { [weak self] in
                self?.deliverSelection(intent: .example)
            }
            bar.onExperiment = { [weak self] in
                self?.deliverSelection(intent: .experiment)
            }
            bar.onCopy = { [weak self] in
                self?.deliverPinnedSelection { text, _, _ in
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
            }
            toolbar = bar
            return bar
        }

        @MainActor private func deliverSelection(intent: ReaderSelectionIntent) {
            deliverPinnedSelection { [weak self] text, pageIndex, position in
                self?.onAskSelection?(text, pageIndex)
                NotificationCenter.default.post(
                    name: .satoriAskSelectionRequested,
                    object: nil,
                    userInfo: [
                        "documentID": self?.documentID as Any,
                        "text": text,
                        "pageIndex": pageIndex,
                        "position": position,
                        "url": self?.observedView?.document?.documentURL as Any,
                        "intent": intent.rawValue
                    ]
                )
            }
        }

        /// The page of the pinned selection (first selected page), falling
        /// back to the reader's current page when the selection is gone.
        @MainActor private func deliverPinnedSelection(_ action: (String, Int, ReadingPosition) -> Void) {
            let text = pinnedSelection
            // Capture the selection's page before the click clears it.
            let pageIndex: Int
            let position: ReadingPosition
            if let view = observedView, let document = view.document,
               let firstPage = view.currentSelection?.pages.first ?? view.currentPage {
                pageIndex = document.index(for: firstPage)
                let selectionOffset = view.currentSelection.map {
                    self.selectionOffset($0, on: firstPage)
                }
                position = ReadingPosition(
                    pageIndex: pageIndex,
                    normalizedPageOffset: selectionOffset ?? visibleOffset(in: view, page: firstPage)
                )
            } else {
                pageIndex = currentPageIndex.wrappedValue
                position = ReadingPosition(pageIndex: pageIndex)
            }
            guard !text.isEmpty else { return }
            // 不清除选区：像 Cursor 一样保留高亮，用户能看见自己问了什么，
            // 也能继续在同一段上补充操作。
            hideToolbar()
            action(text, pageIndex, position)
        }

        @MainActor private func hideToolbar() {
            toolbar?.removeFromSuperview()
        }
    }
}

/// A temporary, non-persistent drag layer for isolating part of a scanned PDF
/// page. It disappears as soon as the crop is delivered or cancelled.
private final class RegionCaptureView: NSView {
    var onComplete: ((NSRect) -> Void)?
    var onCancel: (() -> Void)?

    private var startPoint: NSPoint?
    private var selectionRect: NSRect = .zero

    override var acceptsFirstResponder: Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        startPoint = convert(event.locationInWindow, from: nil)
        selectionRect = .zero
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let startPoint else { return }
        let current = convert(event.locationInWindow, from: nil)
        selectionRect = NSRect(
            x: min(startPoint.x, current.x),
            y: min(startPoint.y, current.y),
            width: abs(current.x - startPoint.x),
            height: abs(current.y - startPoint.y)
        )
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            startPoint = nil
            selectionRect = .zero
            needsDisplay = true
        }
        guard selectionRect.width >= 24, selectionRect.height >= 24 else { return }
        onComplete?(selectionRect)
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !selectionRect.isEmpty else { return }
        SatoriThemeAppKit.accentWash.withAlphaComponent(0.24).setFill()
        NSBezierPath(rect: selectionRect).fill()
        SatoriThemeAppKit.accent.setStroke()
        let border = NSBezierPath(rect: selectionRect)
        border.lineWidth = 2
        border.stroke()
    }
}

/// A small floating bar shown above a PDF text selection — Cursor-style
/// "select and ask". It lives as a direct subview of the PDFView so it can be
/// positioned in the view's coordinate space. Surfaces use the shared theme
/// tokens (SatoriThemeAppKit) so it tracks light/dark automatically.
final class SelectionToolbarView: NSView {
    var onExplain: (() -> Void)?
    var onContext: (() -> Void)?
    var onExample: (() -> Void)?
    var onExperiment: (() -> Void)?
    var onCopy: (() -> Void)?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = SatoriThemeAppKit.paperRaised.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = SatoriThemeAppKit.hairlineStrong.cgColor
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.18
        layer?.shadowRadius = 12
        layer?.shadowOffset = CGSize(width: 0, height: -4)

        let explain = makeButton(title: "理解", symbol: "sparkles", action: #selector(explainTapped), prominent: true)
        let context = makeButton(title: "接上文", symbol: "arrow.turn.up.left", action: #selector(contextTapped), prominent: false)
        let example = makeButton(title: "举例", symbol: "lightbulb", action: #selector(exampleTapped), prominent: false)
        let experiment = makeButton(title: "试试看", symbol: "wand.and.stars", action: #selector(experimentTapped), prominent: false)
        let copy = makeButton(title: "复制", symbol: "doc.on.doc", action: #selector(copyTapped), prominent: false)
        let stack = NSStackView(views: [explain, context, example, experiment, copy])
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 5, bottom: 4, right: 5)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.backgroundColor = SatoriThemeAppKit.paperRaised.cgColor
        layer?.borderColor = SatoriThemeAppKit.hairlineStrong.cgColor
    }

    private func makeButton(title: String, symbol: String, action: Selector, prominent: Bool) -> NSButton {
        let button = SelectionToolbarButton(
            title: title,
            symbol: symbol,
            prominent: prominent,
            target: self,
            action: action
        )
        button.setAccessibilityLabel(title)
        return button
    }

    /// A brief scale-and-fade so the bar feels like it grows out of the
    /// selection rather than snapping into place.
    func playAppearance() {
        guard let layer else { return }
        layer.removeAnimation(forKey: "appear")
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.94
        scale.toValue = 1
        let group = CAAnimationGroup()
        group.animations = [fade, scale]
        group.duration = 0.16
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(group, forKey: "appear")
    }

    @objc private func explainTapped() { onExplain?() }
    @objc private func contextTapped() { onContext?() }
    @objc private func exampleTapped() { onExample?() }
    @objc private func experimentTapped() { onExperiment?() }
    @objc private func copyTapped() { onCopy?() }
}

/// 主题化选中高亮层：覆盖在 PDFKit 系统蓝色选区上的薰衣草圆角视图。
/// 亮暗模式切换时随主题刷新。
private final class SelectionHighlightView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 2
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = SatoriThemeAppKit.selectionHighlight.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.backgroundColor = SatoriThemeAppKit.selectionHighlight.cgColor
    }

    /// The highlight is purely visual. Let PDFKit continue receiving mouse
    /// drags and clicks so a reader can immediately replace the selection
    /// without first dismissing an invisible interaction layer.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A custom-styled button for `SelectionToolbarView`. System bezels are
/// skipped so background, text and icon colors render exactly as designed in
/// both light and dark mode; hover and press give lightweight feedback.
/// Colors come from the shared theme tokens, so this never drifts from the
/// SwiftUI theme.
private final class SelectionToolbarButton: NSButton {
    private let prominent: Bool
    private var hovered = false
    private var pressed = false

    init(title: String, symbol: String, prominent: Bool, target: AnyObject?, action: Selector) {
        self.prominent = prominent
        super.init(frame: .zero)
        self.target = target
        self.action = action
        isBordered = false
        setButtonType(.momentaryChange)
        bezelStyle = .rounded
        controlSize = .small
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        imagePosition = .imageLeading
        imageHugsTitle = true
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.cornerCurve = .continuous
        self.title = title
        // attributedTitle 只在这里设置一次。带 image 的 NSButton 反复设置
        // attributedTitle 会每次都加宽约 3px（AppKit cell 缓存怪癖），
        // hover 触发 updateStyle 会让工具条越变越长、按钮溢出。
        attributedTitle = NSAttributedString(string: " " + title, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: prominent ? SatoriThemeAppKit.onAccent : NSColor.labelColor
        ])
        updateStyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateStyle()
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        updateStyle()
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        pressed = false
        updateStyle()
    }

    override func mouseDown(with event: NSEvent) {
        pressed = true
        updateStyle()
        super.mouseDown(with: event)
        pressed = false
        updateStyle()
    }

    /// Re-applies background, border, text and icon colors from the theme.
    private func updateStyle() {
        guard let layer else { return }
        if prominent {
            let base = hovered ? SatoriThemeAppKit.accentButtonHover : SatoriThemeAppKit.accentButton
            let face = pressed ? (base.blended(withFraction: 0.10, of: .black) ?? base) : base
            layer.backgroundColor = face.cgColor
            layer.borderWidth = 0
            contentTintColor = SatoriThemeAppKit.onAccent
        } else {
            // 胶囊里的次级按钮：平时无底，悬停/按下用薰衣草淡色，图标跟着变强调色。
            if pressed {
                let pressedWash = SatoriThemeAppKit.accentWash.blended(withFraction: 0.30, of: .black)
                    ?? SatoriThemeAppKit.accentWash
                layer.backgroundColor = pressedWash.cgColor
            } else if hovered {
                layer.backgroundColor = SatoriThemeAppKit.accentWash.cgColor
            } else {
                layer.backgroundColor = NSColor.clear.cgColor
            }
            layer.borderWidth = 0
            contentTintColor = hovered ? SatoriThemeAppKit.accent : NSColor.labelColor
        }
    }
}
