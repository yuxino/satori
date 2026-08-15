import Foundation

public actor LearningPlanStore {
    private let fileURL: URL

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
    }

    public func load() throws -> LearningPlan {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return LearningPlan() }
        var plan: LearningPlan
        do {
            let data = try Data(contentsOf: fileURL)
            plan = try StoreArchive.decode(LearningPlan.self, from: data)
        } catch {
            // Undecodable archive: keep the bad file for inspection instead of
            // silently overwriting it, then recover to a fresh default plan.
            try? StoreArchive.backupCorruptFile(at: fileURL)
            plan = LearningPlan()
        }
        for index in plan.courses.indices where plan.courses[index].learningDirectory.isEmpty {
            plan.courses[index].learningDirectory = CourseWorkspace.defaultDirectory(for: plan.courses[index].title)
        }
        return plan
    }

    public func save(_ plan: LearningPlan) throws {
        let data = try StoreArchive.encode(plan)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }

    public static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appending(path: "satori/learning-plan.json")
    }
}
