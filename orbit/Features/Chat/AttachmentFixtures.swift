#if DEBUG
import SwiftUI
import UniformTypeIdentifiers

enum AttachmentFixtures {
    static func load() async -> [DraftAttachment] {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("-attachment-fixture") || args.contains("-attachment-fixtures") else { return [] }
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 240, height: 180))
        let image = renderer.image { context in
            UIColor.systemGray5.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 240, height: 180))
            UIColor.darkGray.setFill()
            context.cgContext.fillEllipse(in: CGRect(x: 70, y: 40, width: 100, height: 100))
        }
        guard let data = image.pngData() else { return [] }
        var sources = [(data, "Planet.png", true)]
        if args.contains("-attachment-fixtures") { sources.append((Data("Attachment fixture".utf8), "notes.txt", false)) }
        var items: [DraftAttachment] = []
        for (data, name, isImage) in sources {
            guard let prepared = try? await Task.detached(operation: { try AttachmentPreparation.prepare(data, name: name, image: isImage) }).value else { continue }
            var item = DraftAttachment(kind: prepared.outgoing.kind, name: prepared.outgoing.name)
            item.payload = prepared.outgoing.payload
            item.byteCount = prepared.outgoing.payload.count
            item.uti = UTType(mimeType: prepared.outgoing.mime) ?? .data
            item.thumbnail = prepared.thumbnail.flatMap { UIImage(data: $0) }
            item.preview = prepared.preview
            item.phase = .ready
            items.append(item)
        }
        return items
    }
}
#endif
