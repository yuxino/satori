import PDFKit
import SwiftUI
import SatoriCore

struct PDFReaderView: NSViewRepresentable {
    let url: URL
    let initialPosition: ReadingPosition
    let onPositionChanged: (Int, Double) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPositionChanged: onPositionChanged) }

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.document = PDFDocument(url: url)
        if let page = view.document?.page(at: initialPosition.pageIndex) { view.go(to: page) }
        context.coordinator.observe(view)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {}

    static func dismantleNSView(_ view: PDFView, coordinator: Coordinator) {
        coordinator.stopObserving()
    }

    final class Coordinator: NSObject {
        private weak var observedView: PDFView?
        private let onPositionChanged: (Int, Double) -> Void

        init(onPositionChanged: @escaping (Int, Double) -> Void) {
            self.onPositionChanged = onPositionChanged
        }

        func observe(_ view: PDFView) {
            observedView = view
            NotificationCenter.default.addObserver(self, selector: #selector(pageChanged), name: Notification.Name.PDFViewPageChanged, object: view)
        }

        func stopObserving() {
            NotificationCenter.default.removeObserver(self)
            observedView = nil
        }

        @MainActor @objc private func pageChanged() {
            guard let view = observedView, let document = view.document, let page = view.currentPage else { return }
            onPositionChanged(document.index(for: page), 0)
        }
    }
}
