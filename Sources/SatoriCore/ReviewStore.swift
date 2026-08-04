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
        questions[index].reviewCount += 1
        questions[index].lastRating = rating
        questions[index].dueAt = Self.nextDue(after: now, rating: rating, reviewCount: questions[index].reviewCount)
        try save(questions, for: documentID)
    }

    /// The spacing schedule, in the spirit of spaced repetition:
    /// again → ~10 minutes; hard → ~1 day; good → grows 2 / 4 / 8 / … days.
    static func nextDue(after now: Date, rating: ReviewRating, reviewCount: Int) -> Date {
        let seconds: TimeInterval
        switch rating {
        case .again:
            seconds = 10 * 60
        case .hard:
            seconds = 24 * 60 * 60
        case .good:
            let days = max(1, min(1 << (reviewCount - 1), 30))
            seconds = Double(days) * 24 * 60 * 60
        }
        return now.addingTimeInterval(seconds)
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
        let data = try Data(contentsOf: fileURL)
        let archive = try JSONDecoder.review.decode(ReviewArchive.self, from: data)
        cachedArchive = archive
        return archive
    }

    private func persist(_ archive: ReviewArchive) throws {
        let data = try JSONEncoder.review.encode(archive)
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

private extension JSONEncoder {
    static var review: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var review: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
