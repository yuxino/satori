import Foundation
import SatoriCore

/// 用 Qwen 识别扫描页图片里的文字。既然应用已经接了 Qwen，
/// 扫描页 OCR 就交给 Qwen——识别质量更高，本地 Vision 只做兜底。
///
/// 调用顺序：
/// 1. 专用 OCR 模型 `qwen-vl-ocr`（百炼兼容模式 chat/completions）；
/// 2. 失败/模型未开通时回退当前配置的对话模型（responses 端点发图转写）；
/// 3. 都失败返回 nil，由调用方回退本地 Vision OCR 或直接发图。
enum QwenOCRService {
    private static let ocrModelID = "qwen-vl-ocr"
    private static let ocrInstruction = "识别这张图片里的全部文字，原样输出，保留段落与换行，不要任何解释或补充。"

    /// 识别页图里的文字；识别失败或未配置时返回 nil。
    static func recognizeText(in imageData: Data, configuration: QwenConfiguration) async -> String? {
        if let text = await recognizeWithDedicatedOCR(imageData: imageData, configuration: configuration) {
            return text
        }
        return await recognizeWithChatModel(imageData: imageData, configuration: configuration)
    }

    // MARK: - 专用 OCR 模型（chat/completions）

    private static func recognizeWithDedicatedOCR(imageData: Data, configuration: QwenConfiguration) async -> String? {
        let endpoint = QwenLearningAssistant.defaultAPIHost.appending(path: "chat/completions")
        let body: [String: Any] = [
            "model": ocrModelID,
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "image_url", "image_url": ["url": imageDataURL(imageData)]],
                    ["type": "text", "text": ocrInstruction]
                ]
            ]],
            "max_tokens": 4096
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body),
              let response = await post(endpoint: endpoint, data: data, apiKey: configuration.apiKey),
              let json = try? JSONSerialization.jsonObject(with: response) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let text = message["content"] as? String, !text.isEmpty else {
            return nil
        }
        return text
    }

    // MARK: - 当前对话模型（responses 端点，发图转写）

    private static func recognizeWithChatModel(imageData: Data, configuration: QwenConfiguration) async -> String? {
        let endpoint = QwenLearningAssistant.defaultAPIHost.appending(path: "responses")
        let body: [String: Any] = [
            "model": configuration.modelID,
            "input": [
                ["type": "input_image", "image_url": imageDataURL(imageData)],
                ["type": "input_text", "text": ocrInstruction]
            ],
            "max_output_tokens": 4096
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body),
              let response = await post(endpoint: endpoint, data: data, apiKey: configuration.apiKey),
              let json = try? JSONSerialization.jsonObject(with: response) as? [String: Any],
              let output = json["output"] as? [[String: Any]] else {
            return nil
        }
        // 取第一个 message 输出里的纯文本。
        for item in output {
            guard item["type"] as? String == "message",
                  let content = item["content"] as? [[String: Any]] else { continue }
            for part in content {
                if let text = part["text"] as? String, !text.isEmpty {
                    return text
                }
            }
        }
        return nil
    }

    // MARK: - 共用

    private static func imageDataURL(_ data: Data) -> String {
        "data:image/jpeg;base64,\(data.base64EncodedString())"
    }

    private static func post(endpoint: URL, data: Data, apiKey: String) async -> Data? {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = data
        do {
            let (responseData, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return nil
            }
            return responseData
        } catch {
            return nil
        }
    }
}
