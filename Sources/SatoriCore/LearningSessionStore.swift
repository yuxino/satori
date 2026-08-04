import Foundation

public actor LearningSessionStore {
    /// Process-wide store for the default on-disk archive.
    ///
    /// Every reading pane must share this instance. Creating a fresh
    /// `LearningSessionStore` per view gives each one its own `cachedArchive`,
    /// so a late async write from one book can overwrite the archive with a
    /// stale snapshot and wipe another book's turns.
    public static let shared = LearningSessionStore()

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
        do {
            let data = try Data(contentsOf: fileURL)
            let archive = try StoreArchive.decode(LearningSessionArchive.self, from: data)
            cachedArchive = archive
            return archive
        } catch {
            // Undecodable archive: keep the bad file aside and recover empty,
            // so the next save starts fresh instead of overwriting the only copy.
            try? StoreArchive.backupCorruptFile(at: fileURL)
            let empty = LearningSessionArchive()
            cachedArchive = empty
            return empty
        }
    }

    private func persist(_ archive: LearningSessionArchive) throws {
        let data = try StoreArchive.encode(archive)
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
