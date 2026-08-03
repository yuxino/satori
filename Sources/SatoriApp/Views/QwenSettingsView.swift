import SwiftUI

struct QwenSettingsView: View {
    @State private var key = ""
    @State private var apiHost = ""
    @State private var status = ""

    var body: some View {
        Form {
            Section("阿里云百炼 · Qwen") {
                SecureField("API Key", text: $key)
                    .textContentType(.password)
                TextField("API Host", text: $apiHost, prompt: Text("https://…/compatible-mode/v1"))
                    .textContentType(.URL)

                Text("创建百炼 API Key 后，把弹窗中的完整 API Key 和 API Host 一起粘贴到这里。密钥只保存在这台 Mac 的钥匙串中。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Link("查看百炼 API Key 获取方法", destination: URL(string: "https://help.aliyun.com/zh/model-studio/get-api-key/")!)
                    .font(.caption)

                HStack {
                    Button("保存连接") {
                        do {
                            try QwenConfigurationStore.save(apiKey: key, apiHost: apiHost)
                            apiHost = QwenConfigurationStore.readAPIHostString()
                            status = "已保存，可以开始使用 Qwen"
                        } catch { status = error.localizedDescription }
                    }
                    .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || apiHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Button("移除连接", role: .destructive) {
                        do {
                            try QwenConfigurationStore.remove()
                            key = ""
                            apiHost = ""
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
            apiHost = QwenConfigurationStore.readAPIHostString()
        }
    }
}
