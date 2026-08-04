import PDFKit
import SwiftUI
import SatoriCore

struct PDFReaderView: NSViewRepresentable {
    let url: URL
    let initialPosition: ReadingPosition
    @Binding var currentPageIndex: Int
    let onPositionChanged: (Int, Double) -> Void
    var onSelectionChanged: ((String) -> Void)?
    /// Cursor-style "select and ask": the floating bar's two actions carry the
    /// text that was selected when the button was clicked, not the live
    /// selection (which the click itself can clear).
    var onExplainSelection: ((String) -> Void)?
    var onComposeSelection: ((String) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(
            currentPageIndex: $currentPageIndex,
            onPositionChanged: onPositionChanged,
            onSelectionChanged: onSelectionChanged,
            onExplainSelection: onExplainSelection,
            onComposeSelection: onComposeSelection
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
        if let page = view.document?.page(at: initialPosition.pageIndex) { view.go(to: page) }
        context.coordinator.observe(view)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        context.coordinator.onSelectionChanged = onSelectionChanged
        context.coordinator.onExplainSelection = onExplainSelection
        context.coordinator.onComposeSelection = onComposeSelection
        guard let document = view.document, document.pageCount > 0 else { return }
        let targetIndex = min(max(currentPageIndex, 0), document.pageCount - 1)
        let visibleIndex = view.currentPage.map(document.index(for:))
        if visibleIndex != targetIndex, let page = document.page(at: targetIndex) {
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
        var onSelectionChanged: ((String) -> Void)?
        var onExplainSelection: ((String) -> Void)?
        var onComposeSelection: ((String) -> Void)?

        private var toolbar: SelectionToolbarView?
        /// The text selected when the toolbar was last shown. Actions use this
        /// so a button click that clears the live selection still asks about
        /// what the reader highlighted.
        private var pinnedSelection = ""

        init(
            currentPageIndex: Binding<Int>,
            onPositionChanged: @escaping (Int, Double) -> Void,
            onSelectionChanged: ((String) -> Void)?,
            onExplainSelection: ((String) -> Void)?,
            onComposeSelection: ((String) -> Void)?
        ) {
            self.currentPageIndex = currentPageIndex
            self.onPositionChanged = onPositionChanged
            self.onSelectionChanged = onSelectionChanged
            self.onExplainSelection = onExplainSelection
            self.onComposeSelection = onComposeSelection
        }

        func observe(_ view: PDFView) {
            observedView = view
            NotificationCenter.default.addObserver(self, selector: #selector(pageChanged), name: Notification.Name.PDFViewPageChanged, object: view)
            NotificationCenter.default.addObserver(self, selector: #selector(selectionChanged), name: Notification.Name.PDFViewSelectionChanged, object: view)
        }

        func stopObserving() {
            NotificationCenter.default.removeObserver(self)
            toolbar?.removeFromSuperview()
            toolbar = nil
            observedView = nil
        }

        @MainActor @objc private func pageChanged() {
            guard let view = observedView, let document = view.document, let page = view.currentPage else { return }
            let pageIndex = document.index(for: page)
            currentPageIndex.wrappedValue = pageIndex
            onPositionChanged(pageIndex, 0)
        }

        @MainActor @objc private func selectionChanged() {
            guard let view = observedView else { return }
            let selection = view.currentSelection
            let text = selection?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            onSelectionChanged?(text)

            if text.isEmpty {
                hideToolbar()
            } else {
                pinnedSelection = text
                showToolbar(for: selection, in: view)
            }
        }

        @MainActor private func showToolbar(for selection: PDFSelection?, in view: PDFView) {
            guard let selection,
                  let page = selection.pages.first else {
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
            bar.onExplain = { [weak self] in
                guard let self else { return }
                let text = self.pinnedSelection
                self.hideToolbar()
                self.clearSelection()
                guard !text.isEmpty else { return }
                self.onExplainSelection?(text)
            }
            bar.onCompose = { [weak self] in
                guard let self else { return }
                let text = self.pinnedSelection
                self.hideToolbar()
                self.clearSelection()
                guard !text.isEmpty else { return }
                self.onComposeSelection?(text)
            }
            toolbar = bar
            return bar
        }

        @MainActor private func clearSelection() {
            observedView?.clearSelection()
        }

        @MainActor private func hideToolbar() {
            toolbar?.removeFromSuperview()
        }
    }
}
