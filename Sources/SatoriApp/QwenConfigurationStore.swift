import Foundation
import LocalAuthentication
import Security
import SatoriCore

extension Notification.Name {
    static let qwenConfigurationDidChange = Notification.Name("qwenConfigurationDidChange")
}

struct QwenConfiguration: Sendable {
    let apiKey: String
    let modelID: String
}

private enum ConfigurationReadOutcome {
    case value(QwenConfiguration?)
    case timeout
}

/// 让钥匙串读取和超时计时器真正解耦。结构化 TaskGroup 在退出时会等待
/// 所有子任务；如果 Security.framework 卡住，单靠 group.cancelAll() 仍会
/// 拖住界面，所以这里用一个小型锁保护的 continuation，只交付第一个结果。
private final class ConfigurationReadRace: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ConfigurationReadOutcome, Never>?
    private var pending: ConfigurationReadOutcome?

    func wait() async -> ConfigurationReadOutcome {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let pending {
                self.pending = nil
                lock.unlock()
                continuation.resume(returning: pending)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    func finish(_ outcome: ConfigurationReadOutcome) {
        lock.lock()
        if let continuation {
            self.continuation = nil
            lock.unlock()
            continuation.resume(returning: outcome)
        } else {
            // Both unstructured tasks can finish before `wait()` installs its
            // continuation; preserve whichever result arrived first.
            if pending == nil { pending = outcome }
            lock.unlock()
        }
    }
}

/// 启动时配置检查和第一次提问可能同时发生。钥匙串读取在某些系统状态
/// 下会等待授权或安全服务响应；共享 in-flight task，避免两个调用各自卡住
/// 一次，也让后续请求直接命中 QwenConfigurationStore 的进程内缓存。
private actor ConfigurationReadGate {
    private var inFlight: Task<QwenConfiguration?, Never>?
    private var unavailableUntil = Date.distantPast

    func value() async -> QwenConfiguration? {
        guard Date() >= unavailableUntil else { return nil }
        if let inFlight {
            return await inFlight.value
        }
        let task = Task.detached(priority: .utility) {
            // 阅读流程不能在后台等待钥匙串弹出交互；需要用户确认时，
            // 让设置页在明确的用户动作中读取/保存一次即可。
            QwenConfigurationStore.read(allowInteraction: false)
        }
        inFlight = task
        let race = ConfigurationReadRace()
        Task.detached(priority: .utility) {
            race.finish(.value(await task.value))
        }
        Task.detached(priority: .utility) {
            try? await Task.sleep(for: .seconds(8))
            race.finish(.timeout)
        }
        let outcome = await race.wait()
        inFlight = nil
        switch outcome {
        case let .value(result):
            return result
        case .timeout:
            // A stuck Keychain Services call must never hold the reading loop
            // hostage. The detached operation may finish later, but new asks
            // fail fast for a short cooldown and can direct the user to Settings.
            unavailableUntil = Date().addingTimeInterval(30)
            return nil
        }
    }
}

enum QwenModelOption: String, CaseIterable, Identifiable {
    case best = "qwen3.7-max-2026-06-08"
    case balanced = "qwen3.7-plus"
    case efficient = "qwen3.7-flash"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .best: "最佳 · Qwen3.7 Max（视觉版）"
        case .balanced: "平衡 · Qwen3.7 Plus"
        case .efficient: "节省 · Qwen3.7 Flash"
        }
    }

    var explanation: String {
        switch self {
        case .best: "理解能力最强，支持扫描页视觉核对；费用最高。"
        case .balanced: "质量、速度和费用更均衡。"
        case .efficient: "速度更快、费用更低，适合日常简单解释。"
        }
    }

    var capabilities: Set<ModelCapability> {
        QwenLearningAssistant.capabilities(for: rawValue)
    }
}

enum QwenConfigurationStore {
    private static let keychainService = "com.yuxino.satori.qwen.v2"
    private static let keychainAccount = "qwen-api-key"
    private static let legacyAPIHostDefaultsKey = "qwen-api-host"
    private static let modelDefaultsKey = "qwen-model-id"
    private static let configuredDefaultsKey = "qwen-is-configured"
    private static let customPromptDefaultsKey = "qwen-custom-prompt"
    /// 创建/重建钥匙串项时应用的签名标识（designated requirement）。
    /// 重签或换证书后该值变化，据此自动重建 ACL，避免授权弹窗反复出现。
    private static let keychainACLRequirementDefaultsKey = "qwen-keychain-acl-requirement"
    private static let storageDirectoryName = "satori"
    private static let keyFilename = "qwen-api-key"

    // MARK: - API Key 进程内缓存

    /// 正常使用期间 `read()` 不再每次访问钥匙串；配置变化时通过
    /// `qwenConfigurationDidChange` 通知失效，重新读取。
    private static let cacheLock = NSLock()
    private nonisolated(unsafe) static var cachedAPIKey: String?
    private static let configurationReadGate = ConfigurationReadGate()

    static func readAsync() async -> QwenConfiguration? {
        await configurationReadGate.value()
    }

    private static func cachedAPIKeyValue() -> String? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return cachedAPIKey
    }

    private static func setCachedAPIKey(_ key: String?) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        cachedAPIKey = key
    }

    private nonisolated(unsafe) static let configurationDidChangeObserver: NSObjectProtocol = {
        NotificationCenter.default.addObserver(
            forName: .qwenConfigurationDidChange,
            object: nil,
            queue: .main
        ) { _ in
            setCachedAPIKey(nil)
        }
    }()

    static func read(allowInteraction: Bool = true) -> QwenConfiguration? {
        _ = configurationDidChangeObserver
        UserDefaults.standard.removeObject(forKey: legacyAPIHostDefaultsKey)
        if let cachedKey = cachedAPIKeyValue() {
            UserDefaults.standard.set(true, forKey: configuredDefaultsKey)
            return QwenConfiguration(apiKey: cachedKey, modelID: readModelID())
        }
        do {
            let apiKey: String
            if let savedKey = try readKeychainAPIKey(allowInteraction: allowInteraction) {
                apiKey = savedKey
                try? removeTransitionalKeyFile()
                ensureKeychainACL(apiKey: apiKey, allowInteraction: allowInteraction)
            } else if let migratedKey = try migrateTransitionalKeyFile(allowInteraction: allowInteraction) {
                apiKey = migratedKey
            } else {
                UserDefaults.standard.set(false, forKey: configuredDefaultsKey)
                return nil
            }
            setCachedAPIKey(apiKey)
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
        // Migrate the pre-release label that was shown in older builds but is
        // not a callable Responses API model ID. Keep the migration local and
        // silent so an existing reader can immediately use the stronger model.
        if saved == "qwen3.8-max" {
            UserDefaults.standard.set(QwenLearningAssistant.defaultModelID, forKey: modelDefaultsKey)
            return QwenLearningAssistant.defaultModelID
        }
        return saved.isEmpty ? QwenLearningAssistant.defaultModelID : saved
    }

    /// 用户自定义的回答提示词；未设置（用内置默认）时返回 nil。
    static func readCustomPrompt() -> String? {
        let saved = UserDefaults.standard.string(forKey: customPromptDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return saved.isEmpty ? nil : saved
    }

    /// 保存自定义提示词；内容为空等同于恢复默认（移除自定义）。
    static func saveCustomPrompt(_ prompt: String) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: customPromptDefaultsKey)
        } else {
            UserDefaults.standard.set(trimmed, forKey: customPromptDefaultsKey)
        }
    }

    static func removeCustomPrompt() {
        UserDefaults.standard.removeObject(forKey: customPromptDefaultsKey)
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
        setCachedAPIKey(normalizedKey)
        try removeTransitionalKeyFile()
        UserDefaults.standard.removeObject(forKey: legacyAPIHostDefaultsKey)
        UserDefaults.standard.set(normalizedModelID, forKey: modelDefaultsKey)
        UserDefaults.standard.set(true, forKey: configuredDefaultsKey)
        recordACLRequirement()
        postConfigurationDidChange()
    }

    static func remove() throws {
        let status = SecItemDelete(keychainLookup as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.status(status)
        }
        setCachedAPIKey(nil)
        try removeTransitionalKeyFile()
        UserDefaults.standard.removeObject(forKey: legacyAPIHostDefaultsKey)
        UserDefaults.standard.removeObject(forKey: modelDefaultsKey)
        UserDefaults.standard.set(false, forKey: configuredDefaultsKey)
        UserDefaults.standard.removeObject(forKey: keychainACLRequirementDefaultsKey)
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

    private static func readKeychainAPIKey(allowInteraction: Bool = true) throws -> String? {
        var query = keychainLookup
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        if !allowInteraction {
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
        }
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

        var attributes = keychainLookup
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccess as String] = try makeTrustedAccess()
        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw KeychainError.status(addStatus) }
    }

    /// 把当前应用加入钥匙串项的信任列表：只有本应用能读，且读取不再弹授权框。
    /// 旧版用空信任列表创建，导致每次启动读取都弹窗。
    private static func makeTrustedAccess() throws -> SecAccess {
        var trustedApp: SecTrustedApplication?
        let appStatus = SecTrustedApplicationCreateFromPath(nil, &trustedApp)
        guard appStatus == errSecSuccess, let trustedApp else {
            throw KeychainError.status(appStatus)
        }
        var access: SecAccess?
        let accessStatus = SecAccessCreate(
            "Satori Qwen API Key" as CFString,
            [trustedApp] as CFArray,
            &access
        )
        guard accessStatus == errSecSuccess, let access else {
            throw KeychainError.status(accessStatus)
        }
        return access
    }

    /// 保证钥匙串项的访问控制信任当前应用：签名标识与记录不一致时
    /// （重新打包、换证书、从旧构建迁移过来），删除并用当前应用重建。
    /// 重建只发生在签名变化后的第一次读取（最多弹一次授权框），之后保持静默。
    /// 拿不到签名标识（未签名调试构建）时跳过，避免反复重建。
    private static func ensureKeychainACL(apiKey: String, allowInteraction: Bool) {
        guard let current = currentAppRequirement() else { return }
        let stored = UserDefaults.standard.string(forKey: keychainACLRequirementDefaultsKey)
        guard stored != current else { return }

        let deleteStatus = SecItemDelete(keychainLookup as CFDictionary)
        guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else { return }
        do {
            try writeKeychainAPIKey(apiKey)
            guard try readKeychainAPIKey(allowInteraction: allowInteraction) == apiKey else { return }
            UserDefaults.standard.set(current, forKey: keychainACLRequirementDefaultsKey)
        } catch {
            // 重建失败：保持现状，下次读取或保存连接时再试。
        }
    }

    /// 当前应用的签名标识（designated requirement）。签名稳定时跨构建不变，
    /// 未签名进程（如调试构建）返回 nil。
    private static func currentAppRequirement() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess, let requirement else { return nil }
        var text: CFString?
        guard SecRequirementCopyString(requirement, [], &text) == errSecSuccess else { return nil }
        return text as String?
    }

    /// 保存连接后记录当前签名标识，与重建的 ACL 保持一致。
    private static func recordACLRequirement() {
        guard let current = currentAppRequirement() else { return }
        UserDefaults.standard.set(current, forKey: keychainACLRequirementDefaultsKey)
    }

    private static func migrateTransitionalKeyFile(allowInteraction: Bool) throws -> String? {
        guard let apiKey = readTransitionalKeyFile() else { return nil }
        try writeKeychainAPIKey(apiKey)
        guard try readKeychainAPIKey(allowInteraction: allowInteraction) == apiKey else {
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
