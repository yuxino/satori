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
}
