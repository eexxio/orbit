import Foundation
import ImageIO
import UniformTypeIdentifiers

struct OutgoingAttachment: Sendable {
    enum Kind: String, Sendable { case image, file }
    let kind: Kind
    let name: String
    let mime: String
    let payload: Data
}

enum AttachmentPreparation {
    struct Prepared: Sendable {
        var outgoing: OutgoingAttachment
        var thumbnail: Data?
        var preview: Data?
    }

    nonisolated static func prepare(_ data: Data, name: String, image: Bool) throws -> Prepared {
        guard data.count <= 20 * 1024 * 1024 else { throw HermesError.server("Files over 20 MB can't be sent") }
        guard image else {
            return Prepared(outgoing: OutgoingAttachment(kind: .file, name: name, mime: UTType(filenameExtension: (name as NSString).pathExtension)?.preferredMIMEType ?? "application/octet-stream", payload: data))
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { throw HermesError.server("Couldn't load this photo") }
        func cgImage(_ size: Int) throws -> CGImage {
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: size] as CFDictionary) else { throw HermesError.server("Couldn't load this photo") }
            return image
        }
        func encode(_ image: CGImage, png: Bool = false, quality: Double) throws -> Data {
            let result = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(result, (png ? UTType.png.identifier : UTType.jpeg.identifier) as CFString, 1, nil) else { throw HermesError.unsupported }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw HermesError.unsupported }
            return result as Data
        }
        let image = try cgImage(2048)
        let alpha = [.first, .last, .premultipliedFirst, .premultipliedLast].contains(image.alphaInfo)
        let gif = (CGImageSourceGetType(source) as String?) == UTType.gif.identifier
        let payload = try gif ? data : encode(image, png: alpha, quality: 0.8)
        let ext = gif ? "gif" : alpha ? "png" : "jpg"
        let filename = (name as NSString).deletingPathExtension + "." + ext
        return try Prepared(outgoing: OutgoingAttachment(kind: .image, name: filename, mime: "image/\(ext == "jpg" ? "jpeg" : ext)", payload: payload), thumbnail: encode(cgImage(160), quality: 0.7), preview: encode(cgImage(320), quality: 0.7))
    }

    nonisolated static func file(_ url: URL) throws -> Prepared {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 20 * 1024 * 1024 else { throw HermesError.server("Files over 20 MB can't be sent") }
        let type = UTType(filenameExtension: url.pathExtension)
        return try prepare(Data(contentsOf: url, options: .mappedIfSafe), name: url.lastPathComponent, image: type?.conforms(to: .image) == true)
    }
}

enum AttachmentMarkers {
    nonisolated static func parse(_ text: String, isUser: Bool) -> (text: String, attachments: [HermesAttachmentRef]) {
        guard isUser else { return (text, []) }
        var refs: [HermesAttachmentRef] = []
        let lines = text.components(separatedBy: "\n").filter { line in
            if line.hasPrefix("[User attached image: "), line.hasSuffix("]") {
                let name = String(line.dropFirst(22).dropLast())
                guard !name.isEmpty else { return true }
                refs.append(HermesAttachmentRef(kind: "image", name: name))
                return false
            }
            if line.hasPrefix("@file:"), !line.contains(" ") {
                let path = String(line.dropFirst(6))
                guard !path.isEmpty else { return true }
                refs.append(HermesAttachmentRef(kind: "file", name: (path as NSString).lastPathComponent))
                return false
            }
            return true
        }
        return (lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines), refs)
    }
}
