import SwiftUI

struct ChatReplyStatus: View {
    let chat: LiveChat
    let showsWaitingIndicator: Bool
    let sendWithoutAttachments: () -> Void

    var body: some View {
        switch chat.replyState {
        case .waiting where showsWaitingIndicator:
            HStack(spacing: 6) {
                Image(systemName: "brain").symbolEffect(.pulse).accessibilityHidden(true)
                Text("Thinking…").accessibilityIdentifier("chat.reply.waiting")
            }
            .font(.subheadline).foregroundStyle(.secondary)
        case .streaming:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini).accessibilityHidden(true)
                Text("Replying…").accessibilityIdentifier("chat.reply.streaming")
            }
            .font(.subheadline).foregroundStyle(.secondary)
        case .stopped:
            HStack(spacing: 6) {
                Image(systemName: "stop.circle").accessibilityHidden(true)
                Text("Stopped").accessibilityIdentifier("chat.reply.stopped")
            }
            .font(.subheadline).foregroundStyle(.secondary)
        case .interrupted(let detail):
            issue("Reply interrupted", detail: detail, identifier: "chat.reply.interrupted")
        case .failed(let detail):
            issue("Reply failed", detail: detail, identifier: "chat.reply.failed")
            if let text = chat.attachmentFallbackText, !text.isEmpty {
                Button("Send without attachments", action: sendWithoutAttachments)
                    .font(.subheadline)
                    .accessibilityIdentifier("chat.sendWithoutAttachments")
            }
        default:
            EmptyView()
        }
    }

    private func issue(_ title: String, detail: String, identifier: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).fontWeight(.semibold).accessibilityIdentifier(identifier)
                Text(detail).foregroundStyle(.secondary).accessibilityIdentifier("chat.reply.error")
            }
        } icon: {
            Image(systemName: "exclamationmark.circle").foregroundStyle(.orange).accessibilityHidden(true)
        }
        .font(.subheadline)
    }
}
