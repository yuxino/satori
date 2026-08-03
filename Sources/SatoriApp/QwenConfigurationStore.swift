import Foundation
import SatoriCore

extension Notification.Name {
    static let qwenConfigurationDidChange = Notification.Name("qwenConfigurationDidChange")
}

struct QwenConfiguration: Sendable {
    let apiKey: String
    let modelID: String
}

enum QwenModelOption: String, CaseIterable, Identifiable {
    case best = "qwen3.8-max"
    case balanced = "qwen3.7-plus"
    case efficient = "qwen3.7-flash"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .best: "最佳 · Qwen3.8 Max"
        case .balanced: "平衡 · Qwen3.7 Plus"
        case .efficient: "节省 · Qwen3.7 Flash"
        }
    }

    var explanation: String {
        switch self {
        case .best: "理解能力最强，适合教材、扫描页和复杂代码；费用最高。"
        case .balanced: "质量、速度和费用更均衡。"
        case .efficient: "速度更快、费用更低，适合日常简单解释。"
        }
    }
}

enum QwenConfigurationStore {
    private static let legacyAPIHostDefaultsKey = "qwen-api-host"
    private static let modelDefaultsKey = "qwen-model-id"
    private static let configuredDefaultsKey = "qwen-is-configured"
    private static let storageDirectoryName = "satori"
    private static let keyFilename = "qwen-api-key"

    static func read() -> QwenConfiguration? {
        UserDefaults.standard.removeObject(forKey: legacyAPIHostDefaultsKey)
        guard let apiKey = readAPIKey(),
              !apiKey.isEmpty else { return nil }
        UserDefaults.standard.set(true, forKey: configuredDefaultsKey)
        return QwenConfiguration(apiKey: apiKey, modelID: readModelID())
    }

    static func hasSavedConfigurationMarker() -> Bool {
        UserDefaults.standard.bool(forKey: configuredDefaultsKey)
    }

    static func readAPIKey() -> String? {
        guard let url = try? storageURL(),
              let data = try? Data(contentsOf: url),
              let key = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty else { return nil }
        return key
    }

    static func readModelID() -> String {
        let saved = UserDefaults.standard.string(forKey: modelDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return saved.isEmpty ? QwenLearningAssistant.defaultModelID : saved
    }

    static func save(apiKey: String, modelID: String) throws {
        let normalizedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedKey.isEmpty else { throw ConfigurationError.emptyAPIKey }
        let normalizedModelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedModelID.isEmpty else { throw ConfigurationError.emptyModelID }

        let url = try storageURL(createDirectory: true)
        try Data(normalizedKey.utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: url.path
        )
        UserDefaults.standard.removeObject(forKey: legacyAPIHostDefaultsKey)
        UserDefaults.standard.set(normalizedModelID, forKey: modelDefaultsKey)
        UserDefaults.standard.set(true, forKey: configuredDefaultsKey)
        postConfigurationDidChange()
    }

    static func remove() throws {
        if let url = try? storageURL(), FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        UserDefaults.standard.removeObject(forKey: legacyAPIHostDefaultsKey)
        UserDefaults.standard.removeObject(forKey: modelDefaultsKey)
        UserDefaults.standard.set(false, forKey: configuredDefaultsKey)
        postConfigurationDidChange()
    }

    private static func postConfigurationDidChange() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .qwenConfigurationDidChange, object: nil)
        }
    }

    private static func storageURL(createDirectory: Bool = false) throws -> URL {
        guard let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw LocalConfigurationError.applicationSupportUnavailable
        }
        let directory = applicationSupport.appendingPathComponent(storageDirectoryName, isDirectory: true)
        if createDirectory {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o700))],
                ofItemAtPath: directory.path
            )
        }
        return directory.appendingPathComponent(keyFilename, isDirectory: false)
    }
}

private enum ConfigurationError: LocalizedError {
    case emptyAPIKey
    case emptyModelID

    var errorDescription: String? {
        switch self {
        case .emptyAPIKey: "请输入百炼 API Key。"
        case .emptyModelID: "请选择一个 Qwen 模型。"
        }
    }
}

private enum LocalConfigurationError: LocalizedError {
    case applicationSupportUnavailable

    var errorDescription: String? { "无法访问 Satori 的本机配置目录。" }
}
