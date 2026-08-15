import Foundation

/// Builds a conservative PDF-page → printed-page map from page-level footer or
/// header candidates. Only monotonic runs with at least three consistent
/// anchors are trusted; isolated numbers in equations, lists, or headings are
/// intentionally ignored.
public enum PrintedPageMapping {
    public static func map(from candidates: [Int?], maximumGap: Int = 12) -> [Int: Int] {
        guard candidates.count >= 3, maximumGap > 0 else { return [:] }

        var result: [Int: Int] = [:]
        var run: [(pageIndex: Int, printedPage: Int)] = []
        var previous: (pageIndex: Int, printedPage: Int)?

        func flush(_ anchors: [(pageIndex: Int, printedPage: Int)]) {
            guard anchors.count >= 3 else { return }
            for pair in zip(anchors, anchors.dropFirst()) {
                let first = pair.0
                let second = pair.1
                let pageGap = second.pageIndex - first.pageIndex
                let printedGap = second.printedPage - first.printedPage
                guard pageGap > 0, pageGap <= maximumGap, printedGap == pageGap else { continue }
                for offset in 0...pageGap {
                    result[first.pageIndex + offset] = first.printedPage + offset
                }
            }
        }

        for (pageIndex, candidate) in candidates.enumerated() {
            guard let printedPage = candidate, printedPage > 0 else { continue }
            let current = (pageIndex: pageIndex, printedPage: printedPage)

            if let previous {
                let pageGap = current.pageIndex - previous.pageIndex
                let printedGap = current.printedPage - previous.printedPage
                if pageGap > 0, pageGap <= maximumGap, printedGap == pageGap {
                    if run.isEmpty { run = [previous] }
                    run.append(current)
                } else {
                    flush(run)
                    run = [current]
                }
            } else {
                run = [current]
            }
            previous = current
        }

        flush(run)
        return result
    }
}
