import Foundation
import Security

extension Notification.Name {
    static let qwenConfigurationDidChange = Notification.Name("qwenConfigurationDidChange")
}

struct QwenConfiguration {
    let apiKey: String
    let apiHost: URL
}

enum QwenConfigurationStore {
    private static let service = "com.yuxino.satori"
    private static let account = "qwen-api-key"
    private static let apiHostDefaultsKey = "qwen-api-host"

    static func read() -> QwenConfiguration? {
        guard let apiKey = readAPIKey(),
              !apiKey.isEmpty,
              let apiHost = readAPIHost() else { return nil }
        return QwenConfiguration(apiKey: apiKey, apiHost: apiHost)
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

    static func save(apiKey: String, apiHost: String) throws {
        let normalizedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedKey.isEmpty else { throw ConfigurationError.emptyAPIKey }
        let normalizedHost = try normalizedAPIHost(apiHost)

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
        NotificationCenter.default.post(name: .qwenConfigurationDidChange, object: nil)
    }

    private static func readAPIHost() -> URL? {
        try? normalizedAPIHost(readAPIHostString())
    }
}

private enum ConfigurationError: LocalizedError {
    case emptyAPIKey
    case invalidAPIHost

    var errorDescription: String? {
        switch self {
        case .emptyAPIKey: "请输入百炼 API Key。"
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
