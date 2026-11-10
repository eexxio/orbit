
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
    @State private var loadedHistory = false
    /// True while an existing chat's history loads and nothing is cached to show.
    @State private var isLoadingHistory = false
    /// Whether the conversation is scrolled to (or near) its newest message.
    @State private var isNearBottom = true


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

    private var emptyState: some View {
        VStack(spacing: 22) {
            Spacer()

            Image(systemName: "sparkle")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 68, height: 68)
                .background(
                    Color(uiColor: .secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 22)
                )

            VStack(spacing: 7) {
                Text("What can I help with?")
                    .font(.title2.weight(.semibold))

                Text("Ask a question, explore an idea, or get something done.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 10) {
                suggestion("Explain something to me")
                suggestion("Help me write or brainstorm")
                suggestion("Plan a project")
            }
            .padding(.horizontal, 28)

            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding()
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

                if isGenerating && streamingID == nil && reasoningID == nil {
                    HStack(spacing: 10) {
                        ProgressView()

                        Text("Thinking…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.leading, 4)
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
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y + geometry.containerSize.height
                >= geometry.contentSize.height + geometry.contentInsets.bottom - 80
        } action: { _, nearBottom in
            isNearBottom = nearBottom
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            guard isNearBottom else { return }
            withAnimation(.easeOut(duration: 0.25)) {
                proxy.scrollTo(Self.bottomID, anchor: .bottom)
            }
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

                if let copyText {
                    HStack(spacing: 20) {
                        Button {
                            UIPasteboard.general.string = copyText
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .accessibilityLabel("Copy reply")
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

    // MARK: - Suggestions

    private func suggestion(_ title: String) -> some View {
        Button {
            draft = title
            composerIsFocused = true
        } label: {
            HStack {
                Text(title)

                Spacer()

                Image(systemName: "arrow.up.left")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .font(.subheadline)
            .foregroundStyle(.primary)
            .padding(14)
            .background(
                Color(uiColor: .secondarySystemBackground),
                in: RoundedRectangle(cornerRadius: 14)
            )
        }
        .buttonStyle(.plain)
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

    // MARK: - Hermes

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
            } else {
                let message = ChatMessage(text: delta, isUser: false)
                streamingID = message.id
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
        chat.onComplete = { finalText in
            if let finalText, !finalText.isEmpty {
                if let id = streamingID, let index = messages.firstIndex(where: { $0.id == id }) {
                    messages[index].text = finalText
                } else if messages.last?.item != HermesMessage(role: "assistant", text: finalText) {
                    // Unless an interim message already sealed this same text.
                    messages.append(ChatMessage(text: finalText, isUser: false))
                }
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
