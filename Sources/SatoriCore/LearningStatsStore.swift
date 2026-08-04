import Foundation

/// Persists `LearningStats` and applies gamification rules (streak + badges)
/// as real behavior is recorded. Shared actor cache, same discipline as the
/// other stores, so multiple reading panes never clobber each other.
public actor LearningStatsStore {
    public static let shared = LearningStatsStore()

    private let fileURL: URL
    private var cachedStats: LearningStats?

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
    }

    public func current() async throws -> LearningStats {
        try load()
    }

    /// Records that a page was read. Tracks distinct pages so the progress bar
    /// reflects how much of the book has been covered.
    public func recordPageRead(documentID: UUID, pageIndex: Int, pageCount: Int, on date: Date = .now) async throws {
        var stats = try load()
        var activity = stats.documentCounts[documentID] ?? .init()
        activity.pagesRead.insert(pageIndex)
        activity.pageCount = max(activity.pageCount, pageCount)
        stats.documentCounts[documentID] = activity
        try await persist(recordActivityDay(stats, on: date))
    }

    public func recordQuestion(documentID: UUID, on date: Date = .now) async throws {
        var stats = try load()
        var activity = stats.documentCounts[documentID] ?? .init()
        activity.questionsAsked += 1
        stats.documentCounts[documentID] = activity
        try await persist(recordActivityDay(stats, on: date))
    }

    public func recordCodeRun(documentID: UUID, on date: Date = .now) async throws {
        var stats = try load()
        var activity = stats.documentCounts[documentID] ?? .init()
        activity.codeRuns += 1
        stats.documentCounts[documentID] = activity
        try await persist(recordActivityDay(stats, on: date))
    }

    /// Marks the day active and updates the streak, then re-evaluates badges.
    private func recordActivityDay(_ stats: LearningStats, on date: Date) -> LearningStats {
        var updated = stats
        let day = Self.dayStart(of: date)

        if let last = updated.lastActiveDay {
            let daysSince = Calendar.current.dateComponents([.day], from: Self.dayStart(of: last), to: day).day ?? 0
            if daysSince == 1 {
                updated.streakDays += 1
            } else if daysSince > 1 {
                updated.streakDays = 1 // chain broken; restart
            }
            // daysSince == 0: same day, streak unchanged
        } else {
            updated.streakDays = 1
        }
        updated.lastActiveDay = day
        updated.longestStreak = max(updated.longestStreak, updated.streakDays)
        updated.unlockedBadges.formUnion(Self.evaluateBadges(in: updated))
        return updated
    }

    /// A book counts as "read" when its progress hits 100%.
    static func evaluateBadges(in stats: LearningStats) -> Set<BadgeID> {
        var earned = Set<BadgeID>()

        let totalQuestions = stats.documentCounts.values.reduce(0) { $0 + $1.questionsAsked }
        let totalRuns = stats.documentCounts.values.reduce(0) { $0 + $1.codeRuns }
        let anyBookDone = stats.documentCounts.values.contains { $0.progress >= 1 }

        if totalQuestions >= 1 { earned.insert(.firstQuestion) }
        if totalQuestions >= 10 { earned.insert(.tenQuestions) }
        if totalRuns >= 1 { earned.insert(.firstCodeRun) }
        if totalRuns >= 10 { earned.insert(.tenCodeRuns) }
        if stats.streakDays >= 3 { earned.insert(.threeDayStreak) }
        if stats.streakDays >= 7 { earned.insert(.sevenDayStreak) }
        if anyBookDone { earned.insert(.firstBook) }

        return earned
    }

    /// Start of the calendar day, for comparing "same day" vs "consecutive day".
    static func dayStart(of date: Date) -> Date {
        Calendar.current.startOfDay(for: date)
    }

    public static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appending(path: "satori/learning-stats.json")
    }

    private func load() throws -> LearningStats {
        if let cachedStats { return cachedStats }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            let empty = LearningStats()
            cachedStats = empty
            return empty
        }
        let data = try Data(contentsOf: fileURL)
        let stats = try JSONDecoder.stats.decode(LearningStats.self, from: data)
        cachedStats = stats
        return stats
    }

    private func persist(_ stats: LearningStats) async throws {
        let data = try JSONEncoder.stats.encode(stats)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
        cachedStats = stats
    }
}

private extension JSONEncoder {
    static var stats: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var stats: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
