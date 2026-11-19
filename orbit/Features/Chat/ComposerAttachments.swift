import SwiftUI
import UniformTypeIdentifiers

struct DraftAttachment: Identifiable, Equatable {
    enum Phase: Equatable { case preparing, ready, sending, failed(String) }
    let id = UUID()
    var kind: OutgoingAttachment.Kind
    var name: String
    var byteCount = 0
    var uti: UTType = .data
    var thumbnail: UIImage?
    var preview: Data?
    var payload: Data?
    var phase: Phase = .preparing
    var outgoing: OutgoingAttachment? {
        guard let payload else { return nil }
        return OutgoingAttachment(kind: kind, name: name, mime: uti.preferredMIMEType ?? "application/octet-stream", payload: payload)
    }
    var descriptor: HermesAttachmentRef { HermesAttachmentRef(kind: kind.rawValue, name: name, thumbnail: preview) }
}

extension UTType {
    var attachmentSymbol: String {
        if conforms(to: .pdf) { return "doc.richtext" }
        if conforms(to: .sourceCode) || conforms(to: .json) || conforms(to: .xml) || conforms(to: .yaml) || conforms(to: .script) { return "chevron.left.forwardslash.chevron.right" }
        if conforms(to: .commaSeparatedText) || conforms(to: .spreadsheet) { return "tablecells" }
        if conforms(to: .archive) { return "doc.zipper" }
        if conforms(to: .audio) { return "waveform" }
        if conforms(to: .movie) { return "film" }
        if conforms(to: .text) { return "doc.text" }
        return "doc"
    }
}

struct AttachmentTray: View {
    @Binding var attachments: [DraftAttachment]
    let retry: (UUID) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var failed: DraftAttachment?
    @State private var removals = 0

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(attachments) { item in
                        tile(item).id(item.id)
                            .transition(reduceMotion ? .opacity : .scale(scale: 0.8).combined(with: .opacity))
                    }
                }.padding(.horizontal, 12).padding(.vertical, 8)
            }
            .scrollIndicators(.hidden)
            .onChange(of: attachments.count) { old, new in
                if new > old, let id = attachments.last?.id { withAnimation { proxy.scrollTo(id, anchor: .trailing) } }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Attachments, \(attachments.count) items")
        .accessibilityIdentifier("chat.tray")
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .snappy(duration: 0.25), value: attachments.count)
        .sensoryFeedback(.impact(weight: .light), trigger: removals)
        .confirmationDialog(failureReason, isPresented: Binding(get: { failed != nil }, set: { if !$0 { failed = nil } }), titleVisibility: .visible) {
            if let failed {
                Button("Try Again") { retry(failed.id) }
                Button("Remove", role: .destructive) { remove(failed) }
            }
        }
    }

    private var failureReason: String {
        if case .failed(let reason) = failed?.phase { return reason }
        return "Couldn't prepare attachment"
    }

    private func remove(_ item: DraftAttachment) {
        attachments.removeAll { $0.id == item.id }
        removals += 1
        AccessibilityNotification.Announcement("\(item.name) removed").post()
    }

    private func tile(_ item: DraftAttachment) -> some View {
        ZStack(alignment: .topTrailing) {
            ZStack {
                if let image = item.thumbnail {
                    Image(uiImage: image).resizable().scaledToFill().frame(width: 64, height: 64).clipped()
                } else {
                    VStack(spacing: 2) {
                        Image(systemName: item.uti.attachmentSymbol).font(.title3).foregroundStyle(.secondary)
                        Text(item.name).lineLimit(typeSize.isAccessibilitySize ? 2 : 1).truncationMode(.middle)
                        Text(Int64(item.byteCount), format: .byteCount(style: .file)).monospacedDigit().foregroundStyle(.secondary)
                    }.font(.caption2).padding(.horizontal, 8).frame(minWidth: 64, maxWidth: 180).frame(height: 64)
                }
            }
            .opacity(item.phase == .ready ? 1 : 0.5)
            .background(Color.secondary.opacity(0.12))
            .clipShape(.rect(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
            .overlay {
                switch item.phase {
                case .preparing, .sending: ProgressView().controlSize(.small)
                case .failed: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange).font(.system(size: 20))
                case .ready: EmptyView()
                }
            }
            .onTapGesture { if case .failed = item.phase { failed = item } }
            Button { remove(item) } label: {
                Image(systemName: "xmark.circle.fill").font(.system(size: 20)).symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color.black.opacity(0.6)).frame(width: 44, height: 44).contentShape(.rect)
            }
            .offset(x: 8, y: -8)
            .accessibilityIdentifier("chat.tray.remove")
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.kind == .image ? "Photo" : "File"), \(item.name), \(phaseLabel(item.phase))")
        .accessibilityAction(named: "Remove") { remove(item) }
        .accessibilityIdentifier("chat.tray.item")
    }

    private func phaseLabel(_ phase: DraftAttachment.Phase) -> String {
        switch phase {
        case .preparing: "loading"
        case .sending: "sending"
        case .failed(let reason): "failed: \(reason)"
        case .ready: "ready"
        }
    }
}
