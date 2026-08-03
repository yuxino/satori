import Foundation

public actor LearningSessionStore {
    private let fileURL: URL
    private var cachedArchive: LearningSessionArchive?

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
    }

    public func turns(for documentID: UUID) throws -> [LearningTurn] {
        try loadArchive().sessions.first(where: { $0.documentID == documentID })?.turns ?? []
    }

    public func save(_ turns: [LearningTurn], for documentID: UUID) throws {
        var archive = try loadArchive()
        archive.sessions.removeAll { $0.documentID == documentID }
        if !turns.isEmpty {
            archive.sessions.append(.init(documentID: documentID, turns: turns))
        }
        archive.sessions.sort { $0.documentID.uuidString < $1.documentID.uuidString }
        try persist(archive)
    }

    public func clear(for documentID: UUID) throws {
        try save([], for: documentID)
    }

    public static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appending(path: "satori/learning-sessions.json")
    }

    private func loadArchive() throws -> LearningSessionArchive {
        if let cachedArchive { return cachedArchive }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            let empty = LearningSessionArchive()
            cachedArchive = empty
            return empty
        }
        let data = try Data(contentsOf: fileURL)
        let archive = try JSONDecoder.learningSessions.decode(LearningSessionArchive.self, from: data)
        cachedArchive = archive
        return archive
    }

    private func persist(_ archive: LearningSessionArchive) throws {
        let data = try JSONEncoder.learningSessions.encode(archive)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
        cachedArchive = archive
    }
}

private struct LearningSessionArchive: Codable {
    var sessions: [DocumentLearningSession] = []
}

private struct DocumentLearningSession: Codable {
    let documentID: UUID
    var turns: [LearningTurn]
}

private extension JSONEncoder {
    static var learningSessions: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var learningSessions: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
