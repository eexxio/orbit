
import SwiftUI
import MarkdownUI

struct ChatInterfaceView: View {

    /// The Hermes session this chat shows; nil starts a new one on the first message.
    let sessionKey: String?

    init(sessionKey: String? = nil) {
        self.sessionKey = sessionKey
    }

    @AppStorage(AppearanceKey.accent) private var accent = Accent.mono
    @AppStorage(AppearanceKey.showToolCalls) private var showToolCalls = true
    @State private var messages: [ChatMessage] = []
    @State private var hermesChat: HermesConversation?
    /// The reply text and thinking blocks still being streamed into, if any.
    @State private var streamingID: UUID?
    @State private var reasoningID: UUID?
    /// When the current reply's first word arrived, for its tokens-per-second rate.
    @State private var streamStart: Date?
    @State private var loadedHistory = false
    /// True while an existing chat's history loads and nothing is cached to show.
    @State private var isLoadingHistory = false
    @State private var scrollPosition = ScrollPosition()


    @State private var draft = ""
    @State private var isGenerating = false

    @FocusState private var composerIsFocused: Bool

    var body: some View {
        NavigationStack {
            Group {
                if isLoadingHistory && messages.isEmpty {
                    loadingState
                } else if messages.isEmpty {
                    emptyState
                } else {
                    conversation
                }
            }
            .background(Color(uiColor: .systemBackground))
            .safeAreaInset(edge: .bottom, spacing: 0) {
                composer
            }
        }
        .task { await loadHistory() }
        .task { await focusComposerForNewChat() }
        .onDisappear {
            hermesChat?.close()
            hermesChat = nil
        }
    }

    // MARK: - Loading State

    private var loadingState: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)

            Text("Loading conversation…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Empty State

    /// Deliberately quiet: says who you are about to talk to, then gets out of the way of the composer.
    private var emptyState: some View {
        VStack(spacing: 8) {
            Text("New chat")
                .font(.title3.weight(.semibold))

            HStack(spacing: 6) {
                Circle()
                    .fill(connectionColor)
                    .frame(width: 6, height: 6)
                Text(destination)
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Sit a little above center, where the eye lands, not behind the keyboard.
        .offset(y: -40)
    }

    /// "default · hermes.local", the profile and host this chat will run on.
    private var destination: String {
        let client = HermesClient.shared
        guard let host = client.baseURL?.host() else { return "No server set" }
        return "\(client.profile) · \(host)"
    }

    private var connectionColor: Color {
        switch HermesClient.shared.state {
        case .connected: .green
        case .connecting: .orange
        case .disconnected, .failed: .secondary
        }
    }

    // MARK: - Conversation

    private var conversation: some View {
        ScrollViewReader { proxy in
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                let copies = replyCopies
                // Hidden tool calls stay in `messages`, so the cache and the toggle keep them.
                ForEach(showToolCalls ? messages : messages.filter { $0.tool == nil }) { message in
                    messageRow(message, copyText: copies[message.id])
                }

                if showsWaitingIndicator {
                    // Styled like a live thinking row, so the wait and the thinking read as one thing.
                    HStack(spacing: 6) {
                        Image(systemName: "brain")
                            .symbolEffect(.pulse)
                        Text("Thinking…")
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }

                Color.clear
                    .frame(height: 1)
                    .id(Self.bottomID)
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)
            .padding(.bottom, 16)
        }
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        // When the keyboard shrinks the view, keep the bottom edge fixed so the
        // conversation moves up with it instead of sliding behind the keyboard.
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        .scrollDismissesKeyboard(.interactively)
        .scrollPosition($scrollPosition)
        // The keyboard (or a taller composer) covers the bottom of the conversation by
        // growing its insets, which a size-change anchor never sees. Shift the content up
        // by the same amount so the messages that were just above the composer stay there.
        .onScrollGeometryChange(for: ScrollGeometry.self) { $0 } action: { old, new in
            let covered = (new.contentInsets.bottom - new.containerSize.height)
                - (old.contentInsets.bottom - old.containerSize.height)
            guard covered > 1 else { return }
            let maxOffset = new.contentSize.height + new.contentInsets.bottom - new.containerSize.height
            let target = min(new.contentOffset.y + covered, maxOffset)
            guard target > new.contentOffset.y + 1 else { return }
            scrollPosition.scrollTo(y: target)
        }
        .onAppear { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
        // A loaded or refreshed history, a sent message, and each streamed word.
        .onChange(of: scrollToken) {
            proxy.scrollTo(Self.bottomID, anchor: .bottom)
        }
        }
    }

    private static let bottomID = "conversation-bottom"

    /// Changes whenever the newest content changes, so the view follows it to the bottom.
    private var scrollToken: String {
        "\(messages.count)|\(messages.last?.text.count ?? 0)|\(isGenerating)"
    }

    /// One copy button per agent reply, under its last text segment, copying all of the reply's
    /// text. A reply still streaming gets none until it finishes.
    private var replyCopies: [UUID: String] {
        var copies: [UUID: String] = [:]
        var segments: [ChatMessage] = []
        func close() {
            if let last = segments.last { copies[last.id] = segments.map(\.text).joined(separator: "\n\n") }
            segments = []
        }
        for message in messages {
            if message.isUser { close() } else if message.role == "assistant" { segments.append(message) }
        }
        if !isGenerating { close() }
        return copies
    }

    // MARK: - Message Row

    @ViewBuilder
    private func messageRow(_ message: ChatMessage, copyText: String?) -> some View {
        if message.role == "reasoning" {
            ReasoningRow(text: message.text, isLive: message.id == reasoningID)
        } else if let tool = message.tool {
            ToolCallRow(tool: tool)
        } else if message.isUser {
            HStack {
                Spacer(minLength: 48)

                Text(message.text)
                    .padding(.horizontal, 15)
                    .padding(.vertical, 11)
                    .foregroundStyle(accent.onColor)
                    .background(
                        accent.color,
                        in: RoundedRectangle(cornerRadius: 20)
                    )
            }
        } else {
            VStack(alignment: .leading, spacing: 12) {
                // Full block-level Markdown: headings, lists, code blocks, quotes, tables.
                Markdown(message.text)
                    .markdownTheme(.basic)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if copyText != nil || message.rate != nil {
                    HStack(spacing: 20) {
                        if let copyText {
                            Button {
                                UIPasteboard.general.string = copyText
                            } label: {
                                Image(systemName: "doc.on.doc")
                            }
                            .accessibilityLabel("Copy reply")
                        }

                        if let rate = message.rate {
                            Label(rate.label, systemImage: "gauge.with.dots.needle.67percent")
                                .font(.caption.monospacedDigit())
                                .contentTransition(.numericText())
                                .accessibilityLabel(rate.accessibilityLabel)
                        }
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Composer

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            // Grows with its text up to six lines, then scrolls.
            TextField("Ask anything", text: $draft, axis: .vertical)
                .focused($composerIsFocused)
                .lineLimit(1...6)
                .padding(.vertical, 11)

            Button {
                sendMessage()
            } label: {
                // Resizable so the circle fills exactly 30pt; a font-sized symbol
                // carries extra baseline space below it and sits off-center.
                Image(systemName: "arrow.up.circle.fill")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 30, height: 30)
            }
            .tint(accent.color)
            .disabled(!canSend)
            .animation(.default, value: canSend)
            .accessibilityLabel("Send")
            .padding(.bottom, 7)
        }
        .padding(.leading, 16)
        .padding(.trailing, 7)
        .frame(minHeight: 44)
        // At rest the bar narrows toward the center; focusing it spreads it full width.
        .frame(maxWidth: composerIsCollapsed ? 240 : .infinity)
        .contentShape(.rect)
        .onTapGesture { composerIsFocused = true }
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 22))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .animation(.spring(duration: 0.4, bounce: 0.2), value: composerIsCollapsed)
    }

    /// Collapsed while unfocused, unless there is a draft that would get squeezed.
    private var composerIsCollapsed: Bool {
        !composerIsFocused && draft.isEmpty
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Send Message

    private func sendMessage() {
        let text = draft.trimmingCharacters(
            in: .whitespacesAndNewlines
        )

        guard !text.isEmpty else { return }

        messages.append(
            ChatMessage(text: text, isUser: true)
        )

        draft = ""
        composerIsFocused = false

        Task { await submit(text) }
    }

    /// Something is on its way but no row shows it yet. A running tool row has its own spinner.
    private var showsWaitingIndicator: Bool {
        guard isGenerating, streamingID == nil, reasoningID == nil else { return false }
        return !(showToolCalls && messages.last?.tool?.isDone == false)
    }

    // MARK: - Hermes

    /// A new chat opens ready to type. The short wait lets the push transition settle,
    /// since focus set mid-animation is dropped and the keyboard never appears.
    private func focusComposerForNewChat() async {
        guard sessionKey == nil, messages.isEmpty else { return }
        try? await Task.sleep(for: .milliseconds(450))
        // Recheck: a message sent during the wait already cleared focus on purpose.
        guard !Task.isCancelled, messages.isEmpty, !isGenerating else { return }
        composerIsFocused = true
    }

    private func loadHistory() async {
        guard !loadedHistory else { return }
        loadedHistory = true
        guard let sessionKey else { return }
        let client = HermesClient.shared

        // The cached copy shows at once; the server's copy replaces it when it arrives.
        if let cached = client.cachedMessages(for: sessionKey), !cached.isEmpty {
            messages = cached.map(ChatMessage.init)
        } else {
            isLoadingHistory = true
        }
        defer { isLoadingHistory = false }

        do {
            let fresh = try await client.messages(for: sessionKey)
            // Don't clobber a turn the user started while this loaded.
            guard !isGenerating else { return }
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

    private func submit(_ text: String) async {
        let chat = hermesChat ?? makeConversation()
        isGenerating = true
        do {
            try await chat.send(text)
        } catch {
            finishTurn(error: error.localizedDescription)
        }
    }

    private func makeConversation() -> HermesConversation {
        let chat = HermesConversation(storedKey: sessionKey)
        chat.onDelta = { delta in
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
        chat.onInterim = { text, alreadyStreamed in
            if !alreadyStreamed { messages.append(ChatMessage(text: text, isUser: false)) }
            streamingID = nil
        }
        chat.onReasoning = { text, replace in
            streamingID = nil
            if let id = reasoningID, let index = messages.firstIndex(where: { $0.id == id }) {
                messages[index].text = replace ? text : messages[index].text + text
            } else {
                let message = ChatMessage(HermesMessage(role: "reasoning", text: text))
                reasoningID = message.id
                messages.append(message)
            }
        }
        chat.onToolStart = { tool in
            streamingID = nil
            reasoningID = nil
            messages.append(ChatMessage(HermesMessage(role: "tool", text: "", tool: tool)))
        }
        chat.onToolComplete = { id, summary in
            guard let index = messages.lastIndex(where: { $0.tool?.id == id }) else { return }
            messages[index].tool?.isDone = true
            messages[index].tool?.summary = summary
        }
        // The final text is the last segment only, so it replaces just that one.
        chat.onComplete = { finalText, outputTokens in
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
            finishTurn(error: nil)
        }
        chat.onError = { message in
            finishTurn(error: message)
        }
        hermesChat = chat
        return chat
    }

    private func finishTurn(error: String?) {
        if let error {
            messages.append(ChatMessage(text: "⚠️ \(error)", isUser: false))
        }
        streamingID = nil
        reasoningID = nil
        streamStart = nil
        isGenerating = false
        // An interrupted or failed turn leaves no spinner running.
        for index in messages.indices where messages[index].tool?.isDone == false {
            messages[index].tool?.isDone = true
        }
        if let key = hermesChat?.storedKey ?? sessionKey {
            let transcript = messages
                .filter { !($0.role == "assistant" && $0.text.hasPrefix("⚠️ ")) }
                .map(\.item)
            HermesClient.shared.cacheMessages(transcript, for: key)
        }
        Task { await HermesClient.shared.refreshSessions() }
    }
}

// MARK: - Chat Message Model

/// A transcript item with a stable identity for the list; reads and writes pass through to it.
@dynamicMemberLookup
private struct ChatMessage: Identifiable {
    let id = UUID()
    var item: HermesMessage
    /// Generation speed, for replies streamed in this session (not kept in the cache).
    var rate: TokenRate?

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

#Preview {
    ChatInterfaceView()
}
