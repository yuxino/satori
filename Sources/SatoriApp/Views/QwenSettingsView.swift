import SwiftUI
import SatoriCore

struct QwenSettingsView: View {
    @State private var key = ""
    @State private var modelID = QwenLearningAssistant.defaultModelID
    @State private var status = ""

    var body: some View {
        Form {
            Section("阿里云百炼 · Qwen") {
                SecureField("API Key", text: $key)
                    .textContentType(.password)

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

                Text("粘贴华北 2（北京）地域的完整 API Key。Satori 已内置百炼连接地址，密钥只保存在这台 Mac 的钥匙串中。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Link("查看百炼 API Key 获取方法", destination: URL(string: "https://help.aliyun.com/zh/model-studio/get-api-key/")!)
                    .font(.caption)

                HStack {
                    Button("保存连接") {
                        do {
                            try QwenConfigurationStore.save(apiKey: key, modelID: modelID)
                            status = "已保存，可以开始使用 Qwen"
                        } catch { status = error.localizedDescription }
                    }
                    .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Button("移除连接", role: .destructive) {
                        do {
                            try QwenConfigurationStore.remove()
                            key = ""
                            modelID = QwenLearningAssistant.defaultModelID
                            status = "已移除 Qwen 连接"
                        } catch { status = error.localizedDescription }
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
        .onAppear {
            key = QwenConfigurationStore.readAPIKey() ?? ""
            modelID = QwenConfigurationStore.readModelID()
        }
    }
}
