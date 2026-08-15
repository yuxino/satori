import Foundation

/// Maps editable course-directory titles onto recovered page numbers.
/// Native PDF outlines and scanned table-of-contents OCR both produce the
/// same `(title, pageIndex, depth, normalizedOffset)` entry shape, so one
/// matching algorithm serves both paths: the recovered TOC becomes part of
/// the editable learning plan instead of living only in a bounded OCR cache.
public enum DirectoryPageLinker {
    /// 返回与输入目录标题一一对应的页索引；无匹配且无剩余条目时为 nil。
    /// 标题按模糊包含匹配（去空白、忽略「第X章」等前缀）；匹配不到时按
    /// 已恢复目录在书中的顺序顺延到下一个节点。
    public static func linkedPageIndices(
        titles: [String],
        entries: [(title: String, pageIndex: Int, depth: Int, normalizedOffset: Double?)]
    ) -> [Int?] {
        guard !entries.isEmpty else { return Array(repeating: nil, count: titles.count) }
        let normalized = entries.map { (normalize($0.title), $0.pageIndex) }
        var cursor = 0
        var result: [Int?] = []
        result.reserveCapacity(titles.count)
        for title in titles {
            let target = normalize(title)
            guard !target.isEmpty else {
                result.append(nil)
                continue
            }
            if let index = bestMatchIndex(for: target, in: normalized, from: cursor) {
                result.append(normalized[index].1)
                cursor = index + 1
            } else if cursor < normalized.count {
                // 退而求其次：按已恢复目录在书中的顺序映射到下一个节点。
                result.append(normalized[cursor].1)
                cursor += 1
            } else {
                result.append(nil)
            }
        }
        return result
    }

    /// 精确相等最优先，其次模糊包含；取标题最短的候选取代最贴合，保证书序单调。
    private static func bestMatchIndex(for target: String, in entries: [(title: String, pageIndex: Int)], from start: Int) -> Int? {
        var bestIndex: Int?
        var bestTitleLength = Int.max
        for index in start..<entries.count {
            let candidate = entries[index].title
            guard !candidate.isEmpty else { continue }
            if candidate == target {
                return index
            }
            let shorterSide = min(candidate.count, target.count)
            guard shorterSide >= 2,
                  candidate.contains(target) || target.contains(candidate),
                  candidate.count < bestTitleLength else { continue }
            bestIndex = index
            bestTitleLength = candidate.count
        }
        return bestIndex
    }

    /// 去空白、忽略「第X章/节/部分」等前缀，用于模糊标题匹配。
    public static func normalize(_ title: String) -> String {
        var result = title.lowercased().filter { !$0.isWhitespace }
        if result.hasPrefix("第") {
            var rest = result.dropFirst()
            while let first = rest.first, Self.isChapterNumber(first) {
                rest = rest.dropFirst()
            }
            if let first = rest.first, Self.isChapterUnit(first) {
                result = String(rest.dropFirst())
            }
        } else {
            for prefix in ["chapter", "chap", "unit", "part", "lesson", "ch"] {
                guard result.hasPrefix(prefix) else { continue }
                let rest = result.dropFirst(prefix.count)
                if let first = rest.first, Self.isChapterNumber(first) {
                    result = String(rest.drop(while: Self.isChapterNumber))
                    break
                }
            }
        }
        return result
    }

    private static func isChapterNumber(_ character: Character) -> Bool {
        character.isNumber || "一二三四五六七八九十百千万零〇两".contains(character)
    }

    private static func isChapterUnit(_ character: Character) -> Bool {
        "章节部分讲篇课".contains(character)
    }
}
