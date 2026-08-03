import Foundation

public actor LearningPlanStore {
    private let fileURL: URL

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
    }

    public func load() throws -> LearningPlan {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return LearningPlan() }
        let data = try Data(contentsOf: fileURL)
        var plan = try JSONDecoder.iso8601.decode(LearningPlan.self, from: data)
        for index in plan.courses.indices where plan.courses[index].learningDirectory.isEmpty {
            plan.courses[index].learningDirectory = CourseWorkspace.defaultDirectory(for: plan.courses[index].title)
        }
        return plan
    }

    public func save(_ plan: LearningPlan) throws {
        let data = try JSONEncoder.pretty.encode(plan)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }

    public static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appending(path: "satori/learning-plan.json")
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
