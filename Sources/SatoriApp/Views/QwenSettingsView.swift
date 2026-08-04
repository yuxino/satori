import SwiftUI
import SatoriCore

struct QwenSettingsView: View {
    @State private var key = ""
    @State private var modelID = QwenLearningAssistant.defaultModelID
    @State private var statusMessage = ""
    @State private var statusIsFailure = false
    @State private var isLoadingKey = true
    @State private var isUpdatingConnection = false
    @State private var isTestingConnection = false
    @State private var hasSavedConfig = false
    @State private var isConfirmingRemoval = false
    @State private var customPrompt = ""
    @State private var promptStatusMessage = ""
    @State private var promptStatusIsFailure = false

    /// 能力来自核心层 `QwenLearningAssistant.capabilities(for:)`，设置页与
    /// 请求前的能力校验共用同一来源，避免标注与实际支持不一致。
    private var selectedCapabilities: String {
        QwenLearningAssistant.capabilities(for: modelID).map(\.localizedTitle).joined(separator: " · ")
    }

    var body: some View {
        Form {
            Section("阿里云百炼 · Qwen") {
                SecureField("API Key", text: $key)
                    .textContentType(.password)
                    .disabled(isLoadingKey || isUpdatingConnection || isTestingConnection)

                Picker("模型", selection: $modelID) {
                    ForEach(QwenModelOption.allCases) { option in
                        Text(capabilityMenuTitle(for: option)).tag(option.rawValue)
                    }
                }

                if let option = QwenModelOption(rawValue: modelID) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(option.explanation)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        // 能力标注：文本 / 图像 / 联网，按当前选择的模型显示。
                        Label(selectedCapabilities, systemImage: "sparkles")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(SatoriTheme.accent)
                            .labelStyle(.titleAndIcon)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(SatoriTheme.accentWash, in: Capsule())
                    }
                }

                Text("粘贴华北 2（北京）地域的完整 API Key。Satori 已内置百炼连接地址，密钥只保存在这台 Mac 的钥匙串中。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Link("查看百炼 API Key 获取方法", destination: URL(string: "https://help.aliyun.com/zh/model-studio/get-api-key/")!)
                    .font(.caption)

                HStack {
                    Button("保存连接") {
                        saveConnection()
                    }
                    .disabled(
                        key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || isLoadingKey
                            || isUpdatingConnection
                            || isTestingConnection
                    )

                    Button("测试连接") {
                        testConnection()
                    }
                    .disabled(
                        key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || isLoadingKey
                            || isUpdatingConnection
                            || isTestingConnection
                    )

                    Button("移除连接", role: .destructive) {
                        isConfirmingRemoval = true
                    }
                    .disabled(!hasSavedConfig || isLoadingKey || isUpdatingConnection || isTestingConnection)

                    if isLoadingKey || isUpdatingConnection || isTestingConnection {
                        ProgressView()
                            .controlSize(.small)
                    }
                }

                if !statusMessage.isEmpty {
                    Label(statusMessage, systemImage: statusIsFailure ? "xmark.circle.fill" : "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(statusIsFailure ? Color.red : Color.green)
                        .textSelection(.enabled)
                }
            }

            Section("回答助手 · 提示词") {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $customPrompt)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .frame(minHeight: 120, maxHeight: 200)
                    if customPrompt.isEmpty {
                        Text("留空 = 使用内置默认提示词")
                            .font(.body)
                            .foregroundStyle(.tertiary)
                            .padding(12)
                            .allowsHitTesting(false)
                    }
                }
                .background(SatoriTheme.paperRaised, in: RoundedRectangle(cornerRadius: SatoriTheme.Radius.sm, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: SatoriTheme.Radius.sm, style: .continuous)
                        .strokeBorder(SatoriTheme.hairline)
                )

                DisclosureGroup("查看默认提示词") {
                    Text(QwenLearningAssistant.defaultLearningInstructions)
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                }
                .font(.caption)

                Text("这段提示词会作为系统指令随每次提问发送给 Qwen，控制回答的组织方式。留空时使用内置默认：先原文依据、再解释、必要时才补充推断。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    Button("保存提示词") { saveCustomPrompt() }
                    Button("恢复默认", role: .destructive) {
                        customPrompt = ""
                        QwenConfigurationStore.removeCustomPrompt()
                        promptStatusMessage = "已恢复默认提示词"
                        promptStatusIsFailure = false
                    }
                    if !promptStatusMessage.isEmpty {
                        Label(
                            promptStatusMessage,
                            systemImage: promptStatusIsFailure ? "xmark.circle.fill" : "checkmark.circle.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(promptStatusIsFailure ? Color.red : Color.green)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 560)
        .alert("移除 Qwen 连接？", isPresented: $isConfirmingRemoval) {
            Button("取消", role: .cancel) { }
            Button("移除", role: .destructive) { removeConnection() }
        } message: {
            Text("API Key 会从这台 Mac 的钥匙串中删除；之后需要重新粘贴并保存才能继续使用。")
        }
        .task {
            let configuration = await Task.detached(priority: .utility) {
                QwenConfigurationStore.read()
            }.value
            guard !Task.isCancelled else { return }
            key = configuration?.apiKey ?? ""
            modelID = configuration?.modelID ?? QwenConfigurationStore.readModelID()
            customPrompt = QwenConfigurationStore.readCustomPrompt() ?? ""
            hasSavedConfig = configuration != nil
            isLoadingKey = false
        }
    }

    private func saveCustomPrompt() {
        QwenConfigurationStore.saveCustomPrompt(customPrompt)
        let isEmpty = customPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        promptStatusMessage = isEmpty ? "已恢复默认提示词" : "提示词已保存，下一次提问生效"
        promptStatusIsFailure = false
    }

    private func capabilityMenuTitle(for option: QwenModelOption) -> String {
        let capabilities = QwenLearningAssistant.capabilities(for: option.rawValue)
            .map(\.localizedTitle)
            .joined(separator: " · ")
        return "\(option.title) · \(capabilities)"
    }

    private func saveConnection() {
        let submittedKey = key
        let submittedModelID = modelID
        isUpdatingConnection = true
        statusMessage = ""
        statusIsFailure = false
        Task {
            let failure = await Task.detached(priority: .userInitiated) {
                do {
                    try QwenConfigurationStore.save(apiKey: submittedKey, modelID: submittedModelID)
                    return nil as String?
                } catch {
                    return error.localizedDescription
                }
            }.value
            isUpdatingConnection = false
            if failure == nil {
                hasSavedConfig = true
            }
            statusMessage = failure ?? "已保存，可以开始使用 Qwen"
            statusIsFailure = failure != nil
        }
    }

    private func removeConnection() {
        isUpdatingConnection = true
        statusMessage = ""
        statusIsFailure = false
        Task {
            let failure = await Task.detached(priority: .userInitiated) {
                do {
                    try QwenConfigurationStore.remove()
                    return nil as String?
                } catch {
                    return error.localizedDescription
                }
            }.value
            isUpdatingConnection = false
            guard let failure else {
                key = ""
                modelID = QwenLearningAssistant.defaultModelID
                hasSavedConfig = false
                statusMessage = "已移除 Qwen 连接"
                statusIsFailure = false
                return
            }
            statusMessage = failure
            statusIsFailure = true
        }
    }

    /// Tests the connection WITHOUT saving anything: sends a minimal request
    /// with the current (unsaved) key + model and reports success/failure.
    private func testConnection() {
        let submittedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let submittedModelID = modelID
        guard !submittedKey.isEmpty else {
            statusMessage = "请先粘贴 API Key 再测试连接。"
            statusIsFailure = true
            return
        }
        isTestingConnection = true
        statusMessage = ""
        statusIsFailure = false
        Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                do {
                    let endpoint = QwenLearningAssistant.defaultAPIHost.appending(path: "responses")
                    var request = URLRequest(url: endpoint)
                    request.httpMethod = "POST"
                    request.setValue("Bearer \(submittedKey)", forHTTPHeaderField: "Authorization")
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.httpBody = try JSONSerialization.data(withJSONObject: [
                        "model": submittedModelID,
                        "input": [["role": "user", "content": [["type": "input_text", "text": "ping"]]]],
                        "stream": false,
                        "store": false,
                        "max_output_tokens": 8
                    ])
                    let (data, response) = try await URLSession.shared.data(for: request)
                    let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                    if (200..<300).contains(statusCode) {
                        return (true, "连接成功：\(submittedModelID) 可以正常应答。")
                    }
                    let message = (try? JSONDecoder().decode(APIErrorEnvelope.self, from: data))?.error.message
                        ?? "HTTP \(statusCode)"
                    return (false, "连接失败：\(message)")
                } catch {
                    return (false, "连接失败：\(error.localizedDescription)")
                }
            }.value
            isTestingConnection = false
            statusMessage = outcome.1
            statusIsFailure = !outcome.0
        }
    }
}

private struct APIErrorEnvelope: Decodable {
    struct APIError: Decodable {
        let message: String
    }
    let error: APIError
}
