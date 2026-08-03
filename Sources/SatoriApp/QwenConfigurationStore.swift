import Foundation
import Security
import SatoriCore

extension Notification.Name {
    static let qwenConfigurationDidChange = Notification.Name("qwenConfigurationDidChange")
}

struct QwenConfiguration {
    let apiKey: String
    let apiHost: URL
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
    private static let service = "com.yuxino.satori"
    private static let account = "qwen-api-key"
    private static let apiHostDefaultsKey = "qwen-api-host"
    private static let modelDefaultsKey = "qwen-model-id"

    static func read() -> QwenConfiguration? {
        guard let apiKey = readAPIKey(),
              !apiKey.isEmpty,
              let apiHost = readAPIHost() else { return nil }
        return QwenConfiguration(apiKey: apiKey, apiHost: apiHost, modelID: readModelID())
    }

    static func readAPIKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func readAPIHostString() -> String {
        UserDefaults.standard.string(forKey: apiHostDefaultsKey) ?? ""
    }

    static func readModelID() -> String {
        let saved = UserDefaults.standard.string(forKey: modelDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return saved.isEmpty ? QwenLearningAssistant.defaultModelID : saved
    }

    static func normalizedAPIHost(_ value: String) throws -> URL {
        var trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        if trimmed.hasSuffix("/responses") {
            trimmed.removeLast("/responses".count)
        }

        guard let components = URLComponents(string: trimmed),
              components.scheme == "https",
              components.host?.isEmpty == false,
              let url = components.url else {
            throw ConfigurationError.invalidAPIHost
        }
        return url
    }

    static func save(apiKey: String, apiHost: String, modelID: String) throws {
        let normalizedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedKey.isEmpty else { throw ConfigurationError.emptyAPIKey }
        let normalizedHost = try normalizedAPIHost(apiHost)
        let normalizedModelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedModelID.isEmpty else { throw ConfigurationError.emptyModelID }

        let data = Data(normalizedKey.utf8)
        let lookup: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let update = SecItemUpdate(lookup as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update != errSecSuccess {
            guard update == errSecItemNotFound else { throw KeychainError.status(update) }
            var add = lookup
            add[kSecValueData as String] = data
            let status = SecItemAdd(add as CFDictionary, nil)
            guard status == errSecSuccess else { throw KeychainError.status(status) }
        }
        UserDefaults.standard.set(normalizedHost.absoluteString, forKey: apiHostDefaultsKey)
        UserDefaults.standard.set(normalizedModelID, forKey: modelDefaultsKey)
        NotificationCenter.default.post(name: .qwenConfigurationDidChange, object: nil)
    }

    static func remove() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.status(status) }
        UserDefaults.standard.removeObject(forKey: apiHostDefaultsKey)
        UserDefaults.standard.removeObject(forKey: modelDefaultsKey)
        NotificationCenter.default.post(name: .qwenConfigurationDidChange, object: nil)
    }

    private static func readAPIHost() -> URL? {
        try? normalizedAPIHost(readAPIHostString())
    }
}

private enum ConfigurationError: LocalizedError {
    case emptyAPIKey
    case emptyModelID
    case invalidAPIHost

    var errorDescription: String? {
        switch self {
        case .emptyAPIKey: "请输入百炼 API Key。"
        case .emptyModelID: "请选择一个 Qwen 模型。"
        case .invalidAPIHost: "API Host 应是百炼提供的 https 地址。"
        }
    }
}

private enum KeychainError: LocalizedError {
    case status(OSStatus)

    var errorDescription: String? { "无法更新 macOS 钥匙串（错误 \(statusCode)）。" }

    private var statusCode: OSStatus {
        if case let .status(value) = self { value } else { errSecInternalError }
    }
}
