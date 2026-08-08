import Foundation

/// Chooses a bounded set of pages that preserves a book's shape when a
/// whole-document request cannot include every page in the model context.
public enum ReadingSamplePlan {
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
