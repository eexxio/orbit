import SwiftUI
import UniformTypeIdentifiers

struct MessageAttachmentsView: View {
    let attachments: [HermesAttachmentRef]
    @State private var selected: Data?
    private var images: [HermesAttachmentRef] { attachments.filter { $0.kind == "image" && $0.thumbnail != nil } }

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if images.count == 1, let data = images.first?.thumbnail, let image = UIImage(data: data) {
                Button { selected = data } label: {
                    Image(uiImage: image).resizable().scaledToFit().frame(maxWidth: 220, maxHeight: 260)
                        .clipShape(.rect(cornerRadius: 16))
                        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
                }.accessibilityLabel("Photo you sent").accessibilityIdentifier("chat.message.attachment")
            } else if images.count > 1 {
                LazyVGrid(columns: [GridItem(.fixed(108)), GridItem(.fixed(108))], spacing: 4) {
                    ForEach(Array(images.prefix(4).enumerated()), id: \.offset) { index, ref in
                        if let data = ref.thumbnail, let image = UIImage(data: data) {
                            Button { selected = data } label: {
                                Image(uiImage: image).resizable().scaledToFill().frame(width: 108, height: 108).clipped()
                                    .overlay {
                                        if index == 3 && images.count > 4 {
                                            Color.black.opacity(0.45).overlay(Text("+\(images.count - 4)").font(.headline).foregroundStyle(.white))
                                        }
                                    }.clipShape(.rect(cornerRadius: 12))
                            }.accessibilityLabel("Photo you sent, \(index + 1) of \(images.count)")
                                .accessibilityIdentifier("chat.message.attachment")
                        }
                    }
                }.frame(width: 220)
            }
            ForEach(Array(attachments.filter { $0.kind != "image" || $0.thumbnail == nil }.enumerated()), id: \.offset) { _, ref in
                VStack(alignment: .leading, spacing: 3) {
                    Label(ref.name, systemImage: ref.kind == "image" ? "photo" : (UTType(filenameExtension: (ref.name as NSString).pathExtension) ?? .data).attachmentSymbol)
                    if ref.kind == "file", let byteCount = ref.byteCount {
                        Text(Int64(byteCount), format: .byteCount(style: .file)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                    .font(.subheadline).padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Color.secondary.opacity(0.12), in: .rect(cornerRadius: 14))
                    .contextMenu { Button("Copy Name") { UIPasteboard.general.string = ref.name } }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(ref.kind == "image" ? "Photo" : "File") you sent, \(ref.name)")
                    .accessibilityIdentifier("chat.message.attachment")
                    .accessibilityValue(ref.byteCount.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "")
            }
        }
        .fullScreenCover(isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } })) {
            if let selected, let image = UIImage(data: selected) { AttachmentImageViewer(image: image) }
        }
    }
}

private struct AttachmentImageViewer: View {
    let image: UIImage
    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1
    @GestureState private var magnification: CGFloat = 1

    var body: some View {
        NavigationStack {
            Image(uiImage: image).resizable().scaledToFit().scaleEffect(scale * magnification)
                .frame(maxWidth: .infinity, maxHeight: .infinity).background(.black)
                .gesture(MagnifyGesture().updating($magnification) { value, state, _ in state = value.magnification }.onEnded { scale = max(1, scale * $0.magnification) })
                .simultaneousGesture(DragGesture().onEnded { if $0.translation.height > 100 { dismiss() } })
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { Button("Close", systemImage: "xmark") { dismiss() } }
                    ToolbarItem(placement: .topBarTrailing) { ShareLink(item: Image(uiImage: image), preview: SharePreview("Photo", image: Image(uiImage: image))) }
                }
        }.preferredColorScheme(.dark)
    }
}
