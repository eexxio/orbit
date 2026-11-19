import SwiftUI

extension ChatInterfaceView {
    func copyMessage(_ text: String) {
        UIPasteboard.general.string = text
        copyCount += 1
        AccessibilityNotification.Announcement("Copied").post()
    }

    func replyText(for message: ChatMessage) -> String {
        guard let index = chat.messages.firstIndex(where: { $0.id == message.id }) else { return message.text }
        let following = chat.messages[index...].prefix(while: { !$0.isUser })
        if let last = following.last(where: { $0.role == "assistant" }), let text = replyCopies[last.id] { return text }
        let start = chat.messages[..<index].lastIndex(where: \.isUser).map { $0 + 1 } ?? 0
        return chat.messages[start...].prefix(while: { !$0.isUser })
            .filter { $0.role == "assistant" && !$0.text.hasPrefix("⚠️ ") }.map(\.text).joined(separator: "\n\n")
    }

    func actions(for target: MessageActionTarget) -> MessageRowActions {
        let message = target.message
        let inLastReply: Bool = {
            guard let user = chat.messages.lastIndex(where: \.isUser),
                  let row = chat.messages.firstIndex(where: { $0.id == message.id }) else { return false }
            return row > user
        }()
        let canRegenerate = chat.isIdle && inLastReply && !target.isWarning
        let editTitle: String? = message.isUser && chat.isIdle ? "Edit as New Message" : nil
        return MessageRowActions(target: target,
                                 enabled: message.isUser || (message.id != chat.streamingID && !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty),
                                 canRegenerate: canRegenerate, editTitle: editTitle, width: rowWidth,
                                 copy: { copyMessage(target.text) },
                                 select: { selectedText = SelectedMessageText(text: message.text) },
                                 share: { sharedText = SelectedMessageText(text: target.text) },
                                 regenerate: { requestRegeneration(anchorID: message.id) }, edit: { beginEditing(message) })
    }

    var editBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "pencil").accessibilityHidden(true)
            Text("New message from edit")
                .accessibilityIdentifier("chat.edit.banner")
            Spacer()
            Button("Cancel editing", systemImage: "xmark.circle.fill") { cancelEdit() }
                .labelStyle(.iconOnly)
                .accessibilityIdentifier("chat.edit.cancel")
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 20)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    func beginEditing(_ message: ChatMessage) {
        guard chat.isIdle else { return }
        if editingID == nil { stashedDraft = draft }
        withAnimation(.snappy(duration: 0.25)) {
            editingID = message.id
            draft = message.text
        }
        composerIsFocused = true
        composerSelection = TextSelection(insertionPoint: draft.endIndex)
        AccessibilityNotification.Announcement("New message from edit").post()
    }

    func cancelEdit() {
        draft = stashedDraft ?? ""
        endEditing()
    }

    func endEditing() {
        withAnimation(.snappy(duration: 0.25)) {
            editingID = nil
            stashedDraft = nil
        }
    }

    func validateEditing() {
        guard let editingID else { return }
        if !chat.isIdle || !chat.messages.contains(where: { $0.id == editingID }) { endEditing() }
    }

    func regenerationConfirmation(for anchorID: UUID?) -> MessageRegenerationConfirmation {
        let presented = Binding {
            confirmsRegeneration && confirmationMessageID == anchorID
        } set: { presented in
            guard confirmationMessageID == anchorID else { return }
            confirmsRegeneration = presented
        }
        return MessageRegenerationConfirmation(isPresented: presented, toolCount: chat.lastReplyToolCount,
                                               regenerate: { performRegeneration() })
    }

    func requestRegeneration(anchorID: UUID? = nil) {
        guard chat.isIdle else { return }
        confirmationMessageID = anchorID ?? chat.messages.reversed().prefix(while: { !$0.isUser })
            .first(where: { $0.role == "assistant" })?.id
        if chat.lastReplyToolCount > 0 { confirmsRegeneration = true }
        else { performRegeneration() }
    }

    func performRegeneration() {
        guard chat.isIdle else { return }
        regenerateCount += 1
        chat.regenerate()
    }
}
