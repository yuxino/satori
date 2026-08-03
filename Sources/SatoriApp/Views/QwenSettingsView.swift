import SwiftUI
import SatoriCore

struct QwenSettingsView: View {
    @State private var key = ""
    @State private var modelID = QwenLearningAssistant.defaultModelID
    @State private var status = ""
    @State private var isLoadingKey = true
    @State private var isUpdatingConnection = false

    var body: some View {
        Form {
            Section("阿里云百炼 · Qwen") {
                SecureField("API Key", text: $key)
                    .textContentType(.password)
                    .disabled(isLoadingKey || isUpdatingConnection)

                Picker("模型", selection: $modelID) {
                    ForEach(QwenModelOption.allCases) { option in
                        Text(option.title).tag(option.rawValue)
                    }
                }

                if let option = QwenModelOption(rawValue: modelID) {
                    Text(option.explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text("粘贴华北 2（北京）地域的完整 API Key。Satori 已内置百炼连接地址，密钥只保存在这台 Mac 的私有配置目录中。")
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
                    )

                    Button("移除连接", role: .destructive) {
                        removeConnection()
                    }
                    .disabled(isLoadingKey || isUpdatingConnection)

                    if isLoadingKey || isUpdatingConnection {
                        ProgressView()
                            .controlSize(.small)
                    }
                }

                if !status.isEmpty {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 560)
        .task {
            modelID = QwenConfigurationStore.readModelID()
            let storedKey = await Task.detached(priority: .utility) {
                QwenConfigurationStore.readAPIKey() ?? ""
            }.value
            guard !Task.isCancelled else { return }
            key = storedKey
            isLoadingKey = false
        }
    }

    private func saveConnection() {
        let submittedKey = key
        let submittedModelID = modelID
        isUpdatingConnection = true
        status = ""
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
            status = failure ?? "已保存，可以开始使用 Qwen"
        }
    }

    private func removeConnection() {
        isUpdatingConnection = true
        status = ""
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
                status = "已移除 Qwen 连接"
                return
            }
            status = failure
        }
    }
}
