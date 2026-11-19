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
        let canRegenerate = chat.isIdle && chat.canRewind && inLastReply && !target.isWarning
        let editTitle: String? = message.isUser && chat.isIdle
            ? (chat.canRewind ? (message.id == chat.lastUserID ? "Edit" : nil) : "Edit as New Message") : nil
        return MessageRowActions(target: target,
                                 enabled: message.isUser || (message.id != chat.streamingID && !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty),
                                 canRegenerate: canRegenerate, editTitle: editTitle, width: rowWidth,
                                 copy: { copyMessage(target.text) },
                                 select: { selectedText = SelectedMessageText(text: message.text) },
                                 share: { sharedText = SelectedMessageText(text: target.text) },
                                 regenerate: { requestReplacement(nil, anchorID: message.id) }, edit: { beginEditing(message) })
    }

    var editBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "pencil").accessibilityHidden(true)
            Text(editsAsNewMessage ? "New message from edit" : "Editing message")
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
        guard chat.isIdle, !chat.canRewind || message.id == chat.lastUserID else { return }
        if editingID == nil { stashedDraft = draft }
        withAnimation(.snappy(duration: 0.25)) {
            editsAsNewMessage = !chat.canRewind
            editingID = message.id
            draft = message.text
        }
        composerIsFocused = true
        composerSelection = TextSelection(insertionPoint: draft.endIndex)
        AccessibilityNotification.Announcement("Editing message").post()
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
        if !chat.isIdle || (!editsAsNewMessage && editingID != chat.lastUserID)
            || !chat.messages.contains(where: { $0.id == editingID }) { endEditing() }
    }

    func isDimmed(_ message: ChatMessage) -> Bool {
        guard !editsAsNewMessage, let editingID,
              let start = chat.messages.firstIndex(where: { $0.id == editingID }),
              let row = chat.messages.firstIndex(where: { $0.id == message.id }) else { return false }
        return row >= start
    }

    func replacementConfirmation(for anchorID: UUID?) -> MessageReplacementConfirmation {
        let presented = Binding {
            confirmsReplacement && confirmationMessageID == anchorID
        } set: { presented in
            guard confirmationMessageID == anchorID else { return }
            confirmsReplacement = presented
        }
        return MessageReplacementConfirmation(isPresented: presented, toolCount: chat.lastReplyToolCount,
                                              regenerate: { performReplacement() }, cancel: { pendingReplacement = nil })
    }

    func requestReplacement(_ text: String?, anchorID: UUID? = nil) {
        guard chat.isIdle, chat.canRewind else { return }
        pendingReplacement = text
        confirmationMessageID = anchorID ?? chat.messages.reversed().prefix(while: { !$0.isUser })
            .first(where: { $0.role == "assistant" })?.id
        if chat.lastReplyToolCount > 0 { confirmsReplacement = true }
        else { performReplacement() }
    }

    func performReplacement() {
        guard chat.isIdle, chat.canRewind else { return }
        let edited = pendingReplacement
        let previousID = editingID
        let previousStash = stashedDraft
        pendingReplacement = nil
        endEditing()
        if edited != nil {
            draft = ""
            composerIsFocused = false
        }
        Task {
            if let edited {
                let succeeded = await chat.resendEdited(edited)
                if !succeeded, chat.isOnScreen, chat.isIdle {
                    draft = edited
                    editingID = previousID
                    stashedDraft = previousStash
                    composerIsFocused = true
                }
            } else { await chat.regenerate() }
        }
    }
}
