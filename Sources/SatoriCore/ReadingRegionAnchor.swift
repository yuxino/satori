import Foundation

/// A stable, document-relative anchor for a region the reader explicitly
/// framed on a PDF page. Coordinates use a top-left origin and are normalized
/// to 0...1, so the crop can be rebuilt after a window resize or app restart
/// without persisting a large image in the learning session.
public struct ReadingRegionAnchor: Codable, Equatable, Sendable {
    public let pageIndex: Int
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(
        pageIndex: Int,
        x: Double,
        y: Double,
        width: Double,
        height: Double
    ) {
        self.pageIndex = max(0, pageIndex)
        let normalizedX = min(max(x, 0), 1)
        let normalizedY = min(max(y, 0), 1)
        let normalizedWidth = min(max(width, 0), 1 - normalizedX)
        let normalizedHeight = min(max(height, 0), 1 - normalizedY)
        self.x = normalizedX
        self.y = normalizedY
        self.width = normalizedWidth
        self.height = normalizedHeight
    }

    public var centerY: Double { y + height / 2 }

    /// Builds a normalized top-left anchor from a rectangle already expressed
    /// in the PDF page's coordinate space. Keeping this conversion in the core
    /// prevents callers from accidentally mixing PDFView coordinates with
    /// PDFPage coordinates when the reader is zoomed or scrolled.
    public init?(pageIndex: Int, pageRect: CGRect, pageBounds: CGRect) {
        let bounds = pageBounds.standardized
        let clipped = pageRect.standardized.intersection(bounds)
        guard bounds.width > 0, bounds.height > 0,
              !clipped.isNull, clipped.width > 0, clipped.height > 0 else {
            return nil
        }
        self.init(
            pageIndex: pageIndex,
            x: (clipped.minX - bounds.minX) / bounds.width,
            y: (bounds.maxY - clipped.maxY) / bounds.height,
            width: clipped.width / bounds.width,
            height: clipped.height / bounds.height
        )
    }

    /// Restores the anchored rectangle in a PDF page's coordinate space.
    /// The result is clipped again so malformed or old persisted anchors can
    /// never ask PDFKit to render outside the page.
    public func pageRect(in pageBounds: CGRect) -> CGRect? {
        let bounds = pageBounds.standardized
        guard bounds.width > 0, bounds.height > 0, width > 0, height > 0 else {
            return nil
        }
        let rect = CGRect(
            x: bounds.minX + x * bounds.width,
            y: bounds.maxY - (y + height) * bounds.height,
            width: width * bounds.width,
            height: height * bounds.height
        ).standardized.intersection(bounds)
        guard !rect.isNull, rect.width > 0, rect.height > 0 else { return nil }
        return rect
    }
}
