import AppKit
import PDFKit
import SwiftUI
import SatoriCore

/// Notification posted by the selection toolbar's「问 AI」button. The learning
/// panel consumes it via ContentView → ReaderSelectionRouter.pendingAskSelection
/// to ask about the selected passage. userInfo: text, pageIndex, url.
extension Notification.Name {
    static let satoriAskSelectionRequested = Notification.Name("satori.askSelectionRequested")
    static let satoriRunSelectionRequested = Notification.Name("satori.runSelectionRequested")
    /// userInfo: url (the PDF), position (ReadingPosition with page + offset).
    static let satoriReaderJumpRequested = Notification.Name("satori.readerJumpRequested")
}

/// The reading canvas. Text selection raises a floating「问 AI / 运行 / 复制」
/// toolbar (AppKit overlay, theme-colored); the page's visible position is
/// reported as a real 0…1 offset instead of a constant 0, and jumps can be
/// targeted at a (page, offset) pair via the satoriReaderJumpRequested channel.
struct PDFReaderView: NSViewRepresentable {
    let url: URL
    let initialPosition: ReadingPosition
    @Binding var currentPageIndex: Int
    let onPositionChanged: (Int, Double) -> Void

    /// Selection toolbar callbacks, in addition to the notification channel:
    /// (selectedText, pageIndex). Defaults keep existing call sites working.
    var onAskSelection: ((String, Int) -> Void)? = nil
    var onRunSelection: ((String, Int) -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(
            currentPageIndex: $currentPageIndex,
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
        context.coordinator.restoreInitialPosition(in: view)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        context.coordinator.onAskSelection = onAskSelection
        context.coordinator.onRunSelection = onRunSelection
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

    final class Coordinator: NSObject {
        private weak var observedView: PDFView?
        private let currentPageIndex: Binding<Int>
        private let onPositionChanged: (Int, Double) -> Void
        var onAskSelection: ((String, Int) -> Void)?
        var onRunSelection: ((String, Int) -> Void)?

        /// The text selected when the toolbar was last shown. Actions use this
        /// so a button click that clears the live selection still acts on what
        /// the reader highlighted.
        private var pinnedSelection = ""
        private var toolbar: SelectionToolbarView?
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

        init(
            currentPageIndex: Binding<Int>,
            onPositionChanged: @escaping (Int, Double) -> Void,
            onAskSelection: ((String, Int) -> Void)?,
            onRunSelection: ((String, Int) -> Void)?
        ) {
            self.currentPageIndex = currentPageIndex
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
                let requestedURL = note.userInfo?["url"] as? URL
                MainActor.assumeIsolated {
                    self?.handleJumpRequest(position: position, requestedURL: requestedURL)
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
            toolbar?.removeFromSuperview()
            toolbar = nil
            observedView = nil
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
                return
            }
            showToolbar(for: selection, in: view)
        }

        /// How far the current page has scrolled past the top of the viewport,
        /// normalized to 0…1. 0 = page top at viewport top; 1 = page bottom at
        /// viewport top. PDFView is non-flipped, so y grows upward.
        private func visibleOffset(in view: PDFView) -> Double {
            guard let page = view.currentPage else { return 0 }
            let pageRect = view.convert(page.bounds(for: .mediaBox), from: page)
            let viewport = view.visibleRect
            let pageHeight = max(pageRect.height, 1)
            let scrolledPast = pageRect.maxY - viewport.maxY
            return min(max(scrolledPast / pageHeight, 0), 1)
        }

        // MARK: Offset-aware jumps

        @MainActor private func handleJumpRequest(position: ReadingPosition?, requestedURL: URL?) {
            guard let position, let view = observedView else { return }
            if let requestedURL, let documentURL = view.document?.documentURL,
               requestedURL.standardizedFileURL != documentURL.standardizedFileURL {
                return // Another document's jump; ignore.
            }
            pendingJump = position
            jump(to: position, in: view)
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
            } else {
                pinnedSelection = text
                showToolbar(for: selection, in: view)
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

            // Prefer anchoring just below the selection: while reading, the
            // space under the selected line is usually text not yet read, so
            // the bar covers nothing important. Fall back to above only when
            // the selection sits too close to the page bottom to fit below.
            // PDFView's subview space is non-flipped (y grows upward).
            let bounds = selection.bounds(for: page)
            let gap: CGFloat = 8
            let selectionTopInView = view.convert(NSPoint(x: bounds.minX, y: bounds.maxY), from: page).y
            let selectionBottomInView = view.convert(NSPoint(x: bounds.minX, y: bounds.minY), from: page).y
            let leftInView = view.convert(NSPoint(x: bounds.minX, y: bounds.minY), from: page).x

            let belowOriginY = selectionBottomInView - gap - size.height
            let aboveOriginY = selectionTopInView + gap
            let originY: CGFloat = belowOriginY >= gap ? belowOriginY : aboveOriginY

            var origin = NSPoint(x: leftInView, y: originY)
            origin.x = min(max(origin.x, gap), max(gap, view.bounds.width - size.width - gap))
            origin.y = min(max(origin.y, gap), max(gap, view.bounds.height - size.height - gap))
            bar.frame = NSRect(origin: origin, size: size)
            if isNewlyShown { bar.playAppearance() }
        }

        @MainActor private func makeToolbar() -> SelectionToolbarView {
            let bar = SelectionToolbarView()
            bar.onAsk = { [weak self] in
                self?.deliverPinnedSelection { text, pageIndex in
                    self?.onAskSelection?(text, pageIndex)
                    NotificationCenter.default.post(
                        name: .satoriAskSelectionRequested,
                        object: nil,
                        userInfo: ["text": text, "pageIndex": pageIndex, "url": self?.observedView?.document?.documentURL as Any]
                    )
                }
            }
            bar.onRun = { [weak self] in
                self?.deliverPinnedSelection { text, pageIndex in
                    self?.onRunSelection?(text, pageIndex)
                    NotificationCenter.default.post(
                        name: .satoriRunSelectionRequested,
                        object: nil,
                        userInfo: ["text": text, "pageIndex": pageIndex, "url": self?.observedView?.document?.documentURL as Any]
                    )
                }
            }
            bar.onCopy = { [weak self] in
                self?.deliverPinnedSelection { text, _ in
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
            }
            toolbar = bar
            return bar
        }

        /// The page of the pinned selection (first selected page), falling
        /// back to the reader's current page when the selection is gone.
        @MainActor private func deliverPinnedSelection(_ action: (String, Int) -> Void) {
            let text = pinnedSelection
            // Capture the selection's page before the click clears it.
            let pageIndex: Int
            if let view = observedView, let document = view.document,
               let firstPage = view.currentSelection?.pages.first ?? view.currentPage {
                pageIndex = document.index(for: firstPage)
            } else {
                pageIndex = currentPageIndex.wrappedValue
            }
            guard !text.isEmpty else { return }
            // 不清除选区：像 Cursor 一样保留高亮，用户能看见自己问了什么，
            // 也能继续在同一段上补充操作。
            hideToolbar()
            action(text, pageIndex)
        }

        @MainActor private func hideToolbar() {
            toolbar?.removeFromSuperview()
        }
    }
}

/// A small floating bar shown above a PDF text selection — Cursor-style
/// "select and ask". It lives as a direct subview of the PDFView so it can be
/// positioned in the view's coordinate space. Surfaces use the shared theme
/// tokens (SatoriThemeAppKit) so it tracks light/dark automatically.
final class SelectionToolbarView: NSView {
    var onAsk: (() -> Void)?
    var onRun: (() -> Void)?
    var onCopy: (() -> Void)?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = SatoriTheme.Radius.md
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = SatoriThemeAppKit.paperRaised.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = SatoriThemeAppKit.hairlineStrong.cgColor
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.28
        layer?.shadowRadius = 16
        layer?.shadowOffset = CGSize(width: 0, height: -4)

        let ask = makeButton(title: "问 AI", symbol: "sparkles", action: #selector(askTapped), prominent: true)
        let run = makeButton(title: "运行", symbol: "play.fill", action: #selector(runTapped), prominent: false)
        let copy = makeButton(title: "复制", symbol: "doc.on.doc", action: #selector(copyTapped), prominent: false)
        let stack = NSStackView(views: [ask, run, copy])
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 5, left: 7, bottom: 5, right: 7)
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

    @objc private func askTapped() { onAsk?() }
    @objc private func runTapped() { onRun?() }
    @objc private func copyTapped() { onCopy?() }
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
        layer?.cornerRadius = SatoriTheme.Radius.sm - 2
        layer?.cornerCurve = .continuous
        self.title = title
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
        let foreground: NSColor
        if prominent {
            let base = hovered ? SatoriThemeAppKit.accentButtonHover : SatoriThemeAppKit.accentButton
            let face = pressed ? (base.blended(withFraction: 0.10, of: .black) ?? base) : base
            layer.backgroundColor = face.cgColor
            layer.borderWidth = 0
            foreground = SatoriThemeAppKit.onAccent
        } else {
            let tinted = hovered || pressed
            layer.backgroundColor = (tinted ? SatoriThemeAppKit.accentWash : SatoriThemeAppKit.paperRaised).cgColor
            layer.borderWidth = 1
            layer.borderColor = SatoriThemeAppKit.hairlineStrong.cgColor
            foreground = .labelColor
        }
        contentTintColor = foreground
        attributedTitle = NSAttributedString(string: " " + title, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: foreground
        ])
    }
}
