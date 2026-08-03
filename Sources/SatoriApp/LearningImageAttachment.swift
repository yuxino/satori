import AppKit
import Foundation

struct LearningImageAttachment: Identifiable {
    let id = UUID()
    let name: String
    let jpegData: Data
    let preview: NSImage
}

enum LearningImageAttachmentLoader {
    private static let maximumDimension: CGFloat = 1_600

    static func load(from url: URL) throws -> LearningImageAttachment {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess { url.stopAccessingSecurityScopedResource() }
        }

        guard let source = NSImage(contentsOf: url), source.size.width > 0, source.size.height > 0 else {
            throw AttachmentError.unreadable
        }

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
              let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.82]),
              let preview = NSImage(data: jpeg) else {
            throw AttachmentError.unreadable
        }

        return LearningImageAttachment(name: url.lastPathComponent, jpegData: jpeg, preview: preview)
    }
}

private enum AttachmentError: LocalizedError {
    case unreadable

    var errorDescription: String? {
        "这张图片无法读取，请换一张常见格式的图片。"
    }
}
