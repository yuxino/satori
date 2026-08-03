import SwiftUI

struct OpenAISettingsView: View {
    @State private var key = ""
    @State private var status = ""

    var body: some View {
        Form {
            Section("OpenAI") {
                SecureField("API Key", text: $key)
                    .textContentType(.password)
                Text("密钥仅保存在这台 Mac 的钥匙串中，不会写入项目文件或上传到 Satori。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("保存到钥匙串") {
                        do {
                            try OpenAIKeyStore.save(key.trimmingCharacters(in: .whitespacesAndNewlines))
                            status = "已保存到钥匙串"
                        } catch { status = error.localizedDescription }
                    }
                    .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("移除密钥", role: .destructive) {
                        do {
                            try OpenAIKeyStore.remove()
                            key = ""
                            status = "已从钥匙串移除"
                        } catch { status = error.localizedDescription }
                    }
                }
                if !status.isEmpty { Text(status).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 520)
        .onAppear { key = OpenAIKeyStore.read() ?? "" }
    }
}
