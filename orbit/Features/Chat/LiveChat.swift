import Foundation
import Observation

/// One open chat's transcript, its gateway conversation, and the turn streaming into it.
///
/// It lives outside the view so a reply keeps streaming after the user leaves the screen:
/// `HermesClient` holds it by session key until the turn ends, and reopening the chat picks
/// up the same object, thinking row and all.
@MainActor @Observable
final class LiveChat {
    enum ReplyState: Equatable {
        case idle, waiting, streaming, completed, stopped
        case interrupted(String), failed(String)

        var isActive: Bool { self == .waiting || self == .streaming }
    }

    /// The stored session key; nil for a new chat until the host assigns one.
    private(set) var key: String?
    var messages: [ChatMessage] = []
    private(set) var replyState: ReplyState = .idle
    var isGenerating: Bool { replyState.isActive }
    /// True while an existing chat's history loads and nothing is cached to show.
    private(set) var isLoadingHistory = false
    /// The reply text and thinking blocks still being streamed into, if any.
    private(set) var streamingID: UUID?
    private(set) var reasoningID: UUID?
    private(set) var liveToolIDs: Set<UUID> = []
    /// Whether a chat screen shows this chat. When none does, it's let go once its turn ends.
    var isOnScreen = false {
        didSet { if !isOnScreen { releaseIfIdle() } }
    }

    /// When the current reply's first word arrived, for its tokens-per-second rate.
    @ObservationIgnored private var streamStart: Date?
    @ObservationIgnored private var loadedHistory = false
    @ObservationIgnored private var conversation: HermesConversation?
    @ObservationIgnored private var latestPromptID: UUID?
    @ObservationIgnored private var pendingInterrupt: Task<Void, Never>?

    init(key: String?) { self.key = key }

    func loadHistory() async {
        guard !loadedHistory else { return }
        loadedHistory = true
        guard let key else { return }
        let client = HermesClient.shared

        // The cached copy shows at once; the server's copy replaces it when it arrives.
        if let cached = client.cachedMessages(for: key), !cached.isEmpty {
            messages = cached.map(ChatMessage.init)
        } else {
            isLoadingHistory = true
        }
        defer { isLoadingHistory = false }

        do {
            let fresh = try await client.messages(for: key)
            // Don't clobber a turn the user started while this loaded.
            guard latestPromptID == nil else { return }
            if fresh != messages.map(\.item) {
                messages = fresh.map(ChatMessage.init)
            }
        } catch {
            // Offline with a cached copy: keep showing it.
            if messages.isEmpty {
                messages.append(ChatMessage(text: "⚠️ \(error.localizedDescription)", isUser: false))
            }
        }
    }

    func refreshHistory() async {
        guard let key, !isGenerating else { return }
        let client = HermesClient.shared
        let scope = client.shortcutScope
        let prompt = latestPromptID
        guard let fresh = try? await client.messages(for: key), !Task.isCancelled,
              scope == client.shortcutScope, prompt == latestPromptID, !isGenerating else { return }
        messages = fresh.map(ChatMessage.init)
    }

    func send(_ text: String) {
        guard !isGenerating, key == nil || HermesClient.shared.shortcutChatReservation != key else { return }
        let prompt = ChatMessage(text: text, isUser: true)
        messages.append(prompt)
        latestPromptID = prompt.id
        replyState = .waiting
        // Held while the turn runs, even if the screen goes away.
        if let key { HermesClient.shared.keepLive(self, as: key) }
        Task {
            await pendingInterrupt?.value
            guard isGenerating, latestPromptID == prompt.id else { return }
            let chat = conversation ?? makeConversation()
            do {
                try await chat.send(text)
                guard conversation === chat else { return }
                adoptKey(chat.storedKey)
            } catch {
                guard conversation === chat, isGenerating, latestPromptID == prompt.id, pendingInterrupt == nil else { return }
                finishTurn(as: .failed(error.localizedDescription))
            }
        }
    }

    func stop() {
        guard isGenerating else { return }
        let chat = conversation
        finishTurn(as: .stopped)
        guard let chat, pendingInterrupt == nil else { return }
        pendingInterrupt = Task {
            let ok = await chat.interrupt(timeout: .seconds(3))
            if !ok, conversation === chat {
                chat.close()
                conversation = nil
            }
            pendingInterrupt = nil
        }
    }

    /// A new chat learns its key from the host; from then on reopening it from the list finds this object.
    private func adoptKey(_ stored: String?) {
        guard key == nil, let stored else { return }
        key = stored
        if isGenerating || isOnScreen { HermesClient.shared.keepLive(self, as: stored) }
    }

    /// Closes the socket and drops the chat from `HermesClient` when nothing needs it any more.
    private func releaseIfIdle() {
        guard !isOnScreen, !isGenerating else { return }
        conversation?.close()
        conversation = nil
        if let key { HermesClient.shared.releaseLive(self, key: key) }
    }

    /// Ends the turn without waiting for the host, for a sign-out or a server change.
    func shutDown() {
        conversation?.close()
        conversation = nil
        if isGenerating { finishTurn(as: .idle) }
    }

    private func makeConversation() -> HermesConversation {
        let chat = HermesConversation(storedKey: key)
        // `[weak self]` throughout: the conversation is owned by this object.
        chat.onDelta = { [weak self] delta in
            guard let self, isGenerating, pendingInterrupt == nil else { return }
            replyState = .streaming
            reasoningID = nil
            if let id = streamingID, let index = messages.firstIndex(where: { $0.id == id }) {
                messages[index].text += delta
                // A live, estimated rate while it streams; the host's count replaces it at the end.
                if let streamStart {
                    messages[index].rate = TokenRate(tokens: nil, text: messages[index].text, since: streamStart)
                }
            } else {
                let message = ChatMessage(text: delta, isUser: false)
                streamingID = message.id
                streamStart = .now
                messages.append(message)
            }
        }
        // Text sent before a tool call is its own segment; whatever streams next starts a new one.
        chat.onInterim = { [weak self] text, alreadyStreamed in
            guard let self, isGenerating, pendingInterrupt == nil else { return }
            replyState = .streaming
            if !alreadyStreamed { messages.append(ChatMessage(text: text, isUser: false)) }
            streamingID = nil
        }
        chat.onReasoning = { [weak self] text, replace in
            guard let self, isGenerating, pendingInterrupt == nil else { return }
            streamingID = nil
            if let id = reasoningID, let index = messages.firstIndex(where: { $0.id == id }) {
                messages[index].text = replace ? text : messages[index].text + text
            } else {
                let message = ChatMessage(HermesMessage(role: "reasoning", text: text))
                reasoningID = message.id
                messages.append(message)
            }
        }
        chat.onToolStart = { [weak self] tool in
            guard let self, isGenerating, pendingInterrupt == nil else { return }
            streamingID = nil
            reasoningID = nil
            let message = ChatMessage(HermesMessage(role: "tool", text: "", tool: tool))
            liveToolIDs.insert(message.id)
            messages.append(message)
        }
        chat.onToolComplete = { [weak self] id, summary in
            guard let self, isGenerating, pendingInterrupt == nil,
                  let index = messages.lastIndex(where: { $0.tool?.id == id && self.liveToolIDs.contains($0.id) }) else { return }
            liveToolIDs.remove(messages[index].id)
            messages[index].tool?.isDone = true
            messages[index].tool?.summary = summary
        }
        // The final text is the last segment only, so it replaces just that one.
        chat.onComplete = { [weak self] finalText, outputTokens, failure in
            guard let self, isGenerating, pendingInterrupt == nil else { return }
            if let finalText, !finalText.isEmpty {
                if let id = streamingID, let index = messages.firstIndex(where: { $0.id == id }) {
                    messages[index].text = finalText
                } else if messages.last?.item != HermesMessage(role: "assistant", text: finalText) {
                    // Unless an interim message already sealed this same text.
                    messages.append(ChatMessage(text: finalText, isUser: false))
                }
            }
            // Only streamed replies get a rate: without deltas there's no start of generation to time from.
            if let id = streamingID, let streamStart, let index = messages.firstIndex(where: { $0.id == id }) {
                // The host counts the whole turn, so its number only fits a reply with no thinking or tools before it.
                let turnStart = (messages.lastIndex(where: \.isUser) ?? -1) + 1
                let soleReply = index == turnStart && index == messages.count - 1
                messages[index].rate = TokenRate(tokens: soleReply ? outputTokens : nil, text: messages[index].text, since: streamStart)
            }
            finishTurn(as: failure.map(ReplyState.failed) ?? .completed)
        }
        chat.onError = { [weak self] message in
            guard let self, pendingInterrupt == nil else { return }
            finishTurn(as: .failed(message))
        }
        chat.onDisconnect = { [weak self] in
            guard let self, pendingInterrupt == nil else { return }
            finishTurn(as: .interrupted(HermesError.socketClosed.localizedDescription))
        }
        conversation = chat
        return chat
    }

    private func finishTurn(as state: ReplyState) {
        guard isGenerating else { return }
        streamingID = nil
        reasoningID = nil
        liveToolIDs.removeAll()
        streamStart = nil
        replyState = state
        adoptKey(conversation?.storedKey)
        switch state {
        case .failed, .interrupted:
            conversation?.close()
            conversation = nil
        default:
            break
        }
        if let key {
            let transcript = messages
                .filter { !($0.role == "assistant" && $0.text.hasPrefix("⚠️ ")) }
                .map(\.item)
            HermesClient.shared.cacheMessages(transcript, for: key)
        }
        Task { await HermesClient.shared.refreshSessions() }
        releaseIfIdle()
    }
}

// MARK: - Chat Message Model

/// A transcript item with a stable identity for the list; reads and writes pass through to it.
@dynamicMemberLookup
struct ChatMessage: Identifiable {
    let id = UUID()
    var item: HermesMessage

    init(_ item: HermesMessage) { self.item = item }

    init(text: String, isUser: Bool) {
        self.init(HermesMessage(role: isUser ? "user" : "assistant", text: text))
    }

    subscript<T>(dynamicMember path: WritableKeyPath<HermesMessage, T>) -> T {
        get { item[keyPath: path] }
        set { item[keyPath: path] = newValue }
    }

    subscript<T>(dynamicMember path: KeyPath<HermesMessage, T>) -> T { item[keyPath: path] }
}
