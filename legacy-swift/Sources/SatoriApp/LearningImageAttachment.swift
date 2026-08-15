import AppKit
import Foundation

struct LearningImageAttachment: Identifiable {
    let id = UUID()
    let name: String
    let jpegData: Data
    let preview: NSImage
}

enum LearningImageAttachmentLoader {
    /// 单张附图最长边上限。附图总量（≤4 张、≤3MB）在请求前还有一道
    /// 预算：超限会降质或丢弃，并把提示带给用户（LearningResponse.attachmentNotice）。
    private static let maximumDimension: CGFloat = 1_200
    private static let jpegCompressionFactor: CGFloat = 0.8

    static func load(from url: URL) throws -> LearningImageAttachment {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess { url.stopAccessingSecurityScopedResource() }
        }

        guard let source = NSImage(contentsOf: url), source.size.width > 0, source.size.height > 0 else {
            throw AttachmentError.unreadable
        }
        return try normalize(source, name: url.lastPathComponent)
    }

    /// Reads image attachments off the pasteboard (Cmd+V). Returns an empty
    /// array when the pasteboard holds no image, so callers can fall back to
    /// text paste.
    static func load(from pasteboard: NSPasteboard) -> [LearningImageAttachment] {
        guard let items = pasteboard.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage] else {
            return []
        }
        return items.enumerated().compactMap { index, image in
            guard image.size.width > 0, image.size.height > 0 else { return nil }
            return try? normalize(image, name: "粘贴图片 \(index + 1)")
        }
    }

    /// 后台并行压缩/缩放一批图片，结果按输入顺序返回；单张失败会被跳过。
    static func normalizeConcurrently(_ items: [(name: String, image: NSImage)]) async -> [LearningImageAttachment] {
        let pairs = await withTaskGroup(of: (Int, LearningImageAttachment?).self) { group in
            var collected: [(Int, LearningImageAttachment?)] = []
            for (index, item) in items.enumerated() {
                group.addTask {
                    let attachment = try? normalize(item.image, name: item.name)
                    return (index, attachment)
                }
            }
            for await pair in group {
                collected.append(pair)
            }
            return collected
        }
        return pairs.sorted { $0.0 < $1.0 }.compactMap { $0.1 }
    }

    /// 后台并行读取并压缩一批图片文件，结果按输入顺序返回；单张失败会被跳过。
    static func loadConcurrently(from urls: [URL]) async -> [LearningImageAttachment] {
        let pairs = await withTaskGroup(of: (Int, LearningImageAttachment?).self) { group in
            var collected: [(Int, LearningImageAttachment?)] = []
            for (index, url) in urls.enumerated() {
                group.addTask {
                    let attachment = try? load(from: url)
                    return (index, attachment)
                }
            }
            for await pair in group {
                collected.append(pair)
            }
            return collected
        }
        return pairs.sorted { $0.0 < $1.0 }.compactMap { $0.1 }
    }

    private static func normalize(_ source: NSImage, name: String) throws -> LearningImageAttachment {
        let scale = min(1, maximumDimension / max(source.size.width, source.size.height))
        let targetSize = NSSize(
            width: max(1, (source.size.width * scale).rounded()),
            height: max(1, (source.size.height * scale).rounded())
        )
        let resized = NSImage(size: targetSize)
        resized.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        source.draw(
            in: NSRect(origin: .zero, size: targetSize),
            from: NSRect(origin: .zero, size: source.size),
            operation: .copy,
            fraction: 1
        )
        resized.unlockFocus()

        guard let tiff = resized.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: Self.jpegCompressionFactor]),
              let preview = NSImage(data: jpeg) else {
            throw AttachmentError.unreadable
        }

        return LearningImageAttachment(name: name, jpegData: jpeg, preview: preview)
    }
}

private enum AttachmentError: LocalizedError {
    case unreadable

    var errorDescription: String? {
        "这张图片无法读取，请换一张常见格式的图片。"
    }
}
