import SwiftUI

@Observable
final class ChatPresentation {
    let id = UUID()
    var chat: LiveChat
    var draft = ""
    var scrollPosition = ScrollPosition(idType: UUID.self)
    var scrollAnchor: UUID?
    var followsLatest = true
    var focusRequest = 0
    var composerFocused = false
    var hasMarkedText = false
    var sendRequest = 0

    init(sessionKey: String?) {
        chat = HermesClient.shared.liveChat(for: sessionKey)
    }

    var hasDraft: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var isDeleting: Bool { chat.key.map(HermesClient.shared.pendingDeletes.contains) ?? false }
    var canSend: Bool {
        hasDraft && !chat.isGenerating && !isDeleting && HermesClient.shared.state == .connected
    }
}
