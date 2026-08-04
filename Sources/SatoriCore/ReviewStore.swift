import Foundation

/// Persists review questions per document, sharing the actor-cache discipline
/// of `LearningSessionStore` so multiple reading panes never clobber each other.
public actor ReviewStore {
    public static let shared = ReviewStore()

    private let fileURL: URL
    private var cachedArchive: ReviewArchive?

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
    }

    public func questions(for documentID: UUID) throws -> [ReviewQuestion] {
        try loadArchive().entries.first(where: { $0.documentID == documentID })?.questions ?? []
    }

    public func dueQuestions(for documentID: UUID, now: Date = .now) throws -> [ReviewQuestion] {
        try questions(for: documentID).filter { $0.dueAt <= now }
    }

    public func save(_ questions: [ReviewQuestion], for documentID: UUID) throws {
        var archive = try loadArchive()
        archive.entries.removeAll { $0.documentID == documentID }
        if !questions.isEmpty {
            archive.entries.append(.init(documentID: documentID, questions: questions))
        }
        try persist(archive)
    }

    public func rate(for documentID: UUID, question: ReviewQuestion, rating: ReviewRating, now: Date = .now) throws {
        var questions = try self.questions(for: documentID)
        guard let index = questions.firstIndex(where: { $0.id == question.id }) else { return }
        var updated = questions[index]
        updated.reviewCount += 1
        updated.lastRating = rating
        switch rating {
        case .good:
            updated.consecutiveGoodCount += 1
        case .hard:
            break // stability (consecutive good streak) is preserved
        case .again:
            updated.consecutiveGoodCount = 0
        }
        updated.lastIntervalDays = Self.intervalDays(after: rating, consecutiveGoodCount: updated.consecutiveGoodCount)
        updated.dueAt = now.addingTimeInterval(updated.lastIntervalDays * 86_400)
        questions[index] = updated
        try save(questions, for: documentID)
    }

    /// SM-2-style spacing schedule:
    /// - good (记住了): consecutive good streak drives 1, 2, 4, 8… days.
    /// - hard (还行): one step behind good — grows with stability but smaller.
    /// - again (生疏): resets the streak and the interval to 1 day.
    static func intervalDays(after rating: ReviewRating, consecutiveGoodCount: Int) -> Double {
        switch rating {
        case .good:
            return pow(2, Double(max(consecutiveGoodCount - 1, 0)))
        case .hard:
            return pow(2, Double(max(consecutiveGoodCount - 1, -1)))
        case .again:
            return 1
        }
    }

    public static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appending(path: "satori/review-questions.json")
    }

    private func loadArchive() throws -> ReviewArchive {
        if let cachedArchive { return cachedArchive }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            let empty = ReviewArchive()
            cachedArchive = empty
            return empty
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let archive = try StoreArchive.decode(ReviewArchive.self, from: data)
            cachedArchive = archive
            return archive
        } catch {
            // Undecodable archive: keep the bad file aside and recover empty,
            // so the next save starts fresh instead of overwriting the only copy.
            try? StoreArchive.backupCorruptFile(at: fileURL)
            let empty = ReviewArchive()
            cachedArchive = empty
            return empty
        }
    }

    private func persist(_ archive: ReviewArchive) throws {
        let data = try StoreArchive.encode(archive)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
        cachedArchive = archive
    }
}

private struct ReviewArchive: Codable {
    var entries: [DocumentReviewEntry] = []
}

private struct DocumentReviewEntry: Codable {
    let documentID: UUID
    var questions: [ReviewQuestion]
}
