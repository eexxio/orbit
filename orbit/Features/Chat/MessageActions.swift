import SwiftUI
import MarkdownUI

enum MessageActionTarget {
    case user(ChatMessage)
    case reply(segment: ChatMessage, replyText: String)

    var message: ChatMessage {
        switch self {
        case .user(let message), .reply(let message, _): message
        }
    }

    var text: String {
        switch self {
        case .user(let message): message.text
        case .reply(_, let text): text
        }
    }

    var isReply: Bool { !message.isUser }
    var isWarning: Bool { isReply && message.text.hasPrefix("⚠️ ") }
}

struct MessageActions: View {
    let target: MessageActionTarget
    let canRegenerate: Bool
    let editTitle: String?
    let copy: () -> Void
    let select: () -> Void
    let regenerate: () -> Void
    let edit: () -> Void

    var body: some View {
        Button("Copy", systemImage: "doc.on.doc", action: copy)
            .accessibilityIdentifier("message.action.copy")
        if !target.isWarning {
            ShareLink(item: target.text) { Label("Share…", systemImage: "square.and.arrow.up") }
                .accessibilityIdentifier("message.action.share")
            if target.isReply {
                Button("Select Text", systemImage: "character.cursor.ibeam", action: select)
                    .accessibilityIdentifier("message.action.select")
            }
            if canRegenerate || editTitle != nil { Divider() }
            if canRegenerate {
                Button("Regenerate", systemImage: "arrow.clockwise", action: regenerate)
                    .accessibilityIdentifier("message.action.regenerate")
            }
            if let editTitle {
                Button(editTitle, systemImage: "pencil", action: edit)
                    .accessibilityIdentifier("message.action.edit")
            }
        }
    }
}

struct MessageReplacementConfirmation: ViewModifier {
    @Binding var isPresented: Bool
    let toolCount: Int
    let regenerate: () -> Void
    let cancel: () -> Void

    func body(content: Content) -> some View {
        content.confirmationDialog("Run this turn again?", isPresented: $isPresented, titleVisibility: .visible) {
            Button("Regenerate", action: regenerate)
            Button("Cancel", role: .cancel, action: cancel)
        } message: {
            Text("This reply ran \(toolCount) tool(s). Running it again may repeat what they did.")
        }
    }
}

struct ReplyPreview: View {
    let text: String
    let width: CGFloat
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        Markdown(text)
            .markdownTheme(.basic)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            .frame(maxHeight: 388, alignment: .top)
            .clipped()
            .mask(alignment: .bottom) {
                if contentHeight > 388 {
                    VStack(spacing: 0) {
                        Rectangle()
                        LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                            .frame(height: 40)
                    }
                } else { Rectangle() }
            }
            .padding(16)
            .frame(width: width)
            .background(Color(uiColor: .systemBackground), in: .rect(cornerRadius: 20))
    }
}

struct SelectedMessageText: Identifiable {
    let id = UUID()
    let text: String
}

struct SelectMessageTextSheet: View {
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ReadOnlyMessageEditor(text: text)
                .navigationTitle("Select Text")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}

/// UITextView preserves selection and cross-block copying without opening an editing keyboard.
private struct ReadOnlyMessageEditor: UIViewRepresentable {
    let text: String

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.textContainerInset = UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) { view.text = text }
}

struct MessageShareSheet: UIViewControllerRepresentable {
    let text: String

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [text], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

struct MessageRowActions: ViewModifier {
    let target: MessageActionTarget
    let enabled: Bool
    let canRegenerate: Bool
    let editTitle: String?
    let width: CGFloat
    let copy: () -> Void
    let select: () -> Void
    let share: () -> Void
    let regenerate: () -> Void
    let edit: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            menu(content)
                .accessibilityActions {
                    Button("Copy", action: copy)
                    if !target.isWarning {
                        Button("Share", action: share)
                        if target.isReply { Button("Select Text", action: select) }
                        if canRegenerate { Button("Regenerate", action: regenerate) }
                        if let editTitle { Button(editTitle, action: edit) }
                    }
                }
        } else { content }
    }

    @ViewBuilder
    private func menu(_ content: Content) -> some View {
        if target.isReply && !target.isWarning {
            content.contextMenu { actions } preview: { ReplyPreview(text: target.message.text, width: width) }
        } else {
            content.contextMenu { actions }
        }
    }

    private var actions: some View {
        MessageActions(target: target, canRegenerate: canRegenerate, editTitle: editTitle,
                       copy: copy, select: select, regenerate: regenerate, edit: edit)
    }
}
