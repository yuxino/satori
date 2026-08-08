import Foundation

/// Chooses a bounded set of pages that preserves a book's shape when a
/// whole-document request cannot include every page in the model context.
public enum ReadingSamplePlan {
    /// Samples a bounded range while keeping its page numbers in the
    /// document's coordinate system. This is used for chapter route maps,
    /// where the book's first pages are irrelevant to the current chapter.
    public static func representativePageIndices(
        in pageRange: ClosedRange<Int>,
        outlinePageIndices: [Int],
        maxCount: Int = 16
    ) -> [Int] {
        let lowerBound = pageRange.lowerBound
        let upperBound = pageRange.upperBound
        guard lowerBound <= upperBound else { return [] }
        let relativeOutline = outlinePageIndices.compactMap { index -> Int? in
            guard pageRange.contains(index) else { return nil }
            return index - lowerBound
        }
        let boundedCount = max(2, maxCount)
        var anchors = Set(relativeOutline)
        anchors.insert(0)
        anchors.insert(pageRange.count - 1)
        if anchors.count >= boundedCount {
            let sortedAnchors = anchors.sorted()
            let lastIndex = sortedAnchors.count - 1
            let bounded = (0..<boundedCount).map { slot in
                let position = Double(slot) * Double(lastIndex) / Double(boundedCount - 1)
                return sortedAnchors[Int(position.rounded())]
            }
            return Array(Set(bounded)).sorted().map { $0 + lowerBound }
        }

        // Keep every outline anchor when it fits, then fill the remaining
        // budget with evenly distributed pages. A dense table of contents
        // still stays bounded by the branch above.
        var selected = anchors
        for slot in 0..<boundedCount {
            let position = Double(slot) * Double(pageRange.count - 1) / Double(boundedCount - 1)
            selected.insert(Int(position.rounded()))
            if selected.count >= boundedCount { break }
        }
        return selected.sorted().map { $0 + lowerBound }
    }

    public static func representativePageIndices(
        pageCount: Int,
        outlinePageIndices: [Int],
        excluding: Set<Int> = []
    ) -> [Int] {
        guard pageCount > 0 else { return [] }

        var selected = Set<Int>()
        for index in 0..<min(pageCount, 3) {
            selected.insert(index)
        }
        selected.insert(pageCount - 1)

        let stride = max(1, pageCount / 12)
        var sampled = 0
        while sampled < pageCount {
            selected.insert(sampled)
            sampled += stride
        }

        for index in outlinePageIndices where (0..<pageCount).contains(index) {
            selected.insert(index)
        }

        return selected
            .filter { !excluding.contains($0) }
            .sorted()
    }
}
