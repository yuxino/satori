import Foundation
import Security
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
    private static let keychainService = "com.yuxino.satori.qwen.v2"
    private static let keychainAccount = "qwen-api-key"
    private static let legacyAPIHostDefaultsKey = "qwen-api-host"
    private static let modelDefaultsKey = "qwen-model-id"
    private static let configuredDefaultsKey = "qwen-is-configured"
    private static let storageDirectoryName = "satori"
    private static let keyFilename = "qwen-api-key"

    static func read() -> QwenConfiguration? {
        UserDefaults.standard.removeObject(forKey: legacyAPIHostDefaultsKey)
        do {
            let apiKey: String
            if let savedKey = try readKeychainAPIKey() {
                apiKey = savedKey
                try? removeTransitionalKeyFile()
            } else if let migratedKey = try migrateTransitionalKeyFile() {
                apiKey = migratedKey
            } else {
                UserDefaults.standard.set(false, forKey: configuredDefaultsKey)
                return nil
            }
            UserDefaults.standard.set(true, forKey: configuredDefaultsKey)
            return QwenConfiguration(apiKey: apiKey, modelID: readModelID())
        } catch {
            return nil
        }
    }

    static func hasSavedConfigurationMarker() -> Bool {
        UserDefaults.standard.bool(forKey: configuredDefaultsKey)
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

        try writeKeychainAPIKey(normalizedKey)
        guard try readKeychainAPIKey() == normalizedKey else {
            throw KeychainError.verificationFailed
        }
        try removeTransitionalKeyFile()
        UserDefaults.standard.removeObject(forKey: legacyAPIHostDefaultsKey)
        UserDefaults.standard.set(normalizedModelID, forKey: modelDefaultsKey)
        UserDefaults.standard.set(true, forKey: configuredDefaultsKey)
        postConfigurationDidChange()
    }

    static func remove() throws {
        let status = SecItemDelete(keychainLookup as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.status(status)
        }
        try removeTransitionalKeyFile()
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

    private static var keychainLookup: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
    }

    private static func readKeychainAPIKey() throws -> String? {
        var query = keychainLookup
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.status(status) }
        guard let data = item as? Data,
              let key = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty else {
            throw KeychainError.invalidData
        }
        return key
    }

    private static func writeKeychainAPIKey(_ apiKey: String) throws {
        let data = Data(apiKey.utf8)
        let updateStatus = SecItemUpdate(
            keychainLookup as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainError.status(updateStatus)
        }

        var access: SecAccess?
        let accessStatus = SecAccessCreate("Satori Qwen API Key" as CFString, nil, &access)
        guard accessStatus == errSecSuccess, let access else {
            throw KeychainError.status(accessStatus)
        }

        var attributes = keychainLookup
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccess as String] = access
        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw KeychainError.status(addStatus) }
    }

    private static func migrateTransitionalKeyFile() throws -> String? {
        guard let apiKey = readTransitionalKeyFile() else { return nil }
        try writeKeychainAPIKey(apiKey)
        guard try readKeychainAPIKey() == apiKey else {
            throw KeychainError.verificationFailed
        }
        try removeTransitionalKeyFile()
        return apiKey
    }

    private static func readTransitionalKeyFile() -> String? {
        guard let url = try? transitionalKeyFileURL(),
              let data = try? Data(contentsOf: url),
              let key = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty else { return nil }
        return key
    }

    private static func removeTransitionalKeyFile() throws {
        guard let url = try? transitionalKeyFileURL(),
              FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    private static func transitionalKeyFileURL() throws -> URL {
        guard let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw LocalConfigurationError.applicationSupportUnavailable
        }
        let directory = applicationSupport.appendingPathComponent(storageDirectoryName, isDirectory: true)
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

private enum KeychainError: LocalizedError {
    case status(OSStatus)
    case invalidData
    case verificationFailed

    var errorDescription: String? {
        switch self {
        case let .status(status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "错误 \(status)"
            return "无法访问 macOS 钥匙串：\(message)"
        case .invalidData:
            return "macOS 钥匙串中的 API Key 无法读取。"
        case .verificationFailed:
            return "API Key 写入钥匙串后未能通过读取验证。"
        }
    }
}
