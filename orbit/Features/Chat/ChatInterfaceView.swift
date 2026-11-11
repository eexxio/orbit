
import SwiftUI
import MarkdownUI

struct ChatInterfaceView: View {

    /// The Hermes session this chat shows; nil starts a new one on the first message.
    let sessionKey: String?

    init(sessionKey: String? = nil) {
        self.sessionKey = sessionKey
        // A chat still replying in the background comes back as it is, not reloaded.
        _chat = State(initialValue: HermesClient.shared.liveChat(for: sessionKey))
    }

    @AppStorage(AppearanceKey.accent) private var accent = Accent.mono
    @AppStorage(AppearanceKey.showToolCalls) private var showToolCalls = true
    @State private var chat: LiveChat
    @State private var scrollPosition = ScrollPosition()
    @State private var draft = ""

    @FocusState private var composerIsFocused: Bool

    var body: some View {
        NavigationStack {
            Group {
                if chat.isLoadingHistory && chat.messages.isEmpty {
                    loadingState
                } else if chat.messages.isEmpty {
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
        .task { await chat.loadHistory() }
        .task { await focusComposerForNewChat() }
        .onAppear { chat.isOnScreen = true }
        // Only lets the chat go if no turn is running; otherwise it finishes in the background.
        .onDisappear { chat.isOnScreen = false }
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
        GeometryReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    let copies = replyCopies
                    // Hidden tool calls stay in `messages`, so the cache and the toggle keep them.
                    ForEach(showToolCalls ? chat.messages : chat.messages.filter { $0.tool == nil }) { message in
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
                }
                .padding(.horizontal, 18)
                .padding(.top, 8)
                .padding(.bottom, 16)
                // A conversation stacks up from the composer: a short one sits just above
                // the input field instead of hanging from the navigation bar and leaving a
                // well of empty space above it.
                .frame(minHeight: proxy.size.height, alignment: .bottom)
            }
            // An existing chat opens at its newest message, however long its history is.
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .defaultScrollAnchor(.bottom, for: .sizeChanges)
            .scrollDismissesKeyboard(.interactively)
            .scrollPosition($scrollPosition)
            // The rows of a lazy stack report their real height a frame or two after they
            // appear, and the keyboard (or a taller composer) grows the bottom inset. Both
            // push the newest message below the composer unless the view follows them down.
            .onScrollGeometryChange(for: ScrollGeometry.self) { $0 } action: { old, new in
                let grewContent = new.contentSize.height > old.contentSize.height + 0.5
                let grewInset = new.contentInsets.bottom > old.contentInsets.bottom + 0.5
                guard grewContent || grewInset else { return }
                pinToBottom()
            }
            .onAppear { pinToBottom() }
            // A loaded or refreshed history, a sent message, and each streamed word.
            .onChange(of: scrollToken) { pinToBottom() }
        }
    }

    /// Puts the newest message directly above the composer.
    ///
    /// Scrolling to an edge rather than to a view id: on the first layout pass a lazy
    /// stack has not realized its last row yet, so an id-based scroll has nothing to aim
    /// at and the chat opens short of the bottom. The edge also keeps its position when
    /// the content grows, which is what streaming and late layout both need.
    private func pinToBottom() {
        scrollPosition.scrollTo(edge: .bottom)
    }

    /// Changes whenever the newest content changes, so the view follows it to the bottom.
    private var scrollToken: String {
        "\(chat.messages.count)|\(chat.messages.last?.text.count ?? 0)|\(chat.isGenerating)"
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
        for message in chat.messages {
            if message.isUser { close() } else if message.role == "assistant" { segments.append(message) }
        }
        if !chat.isGenerating { close() }
        return copies
    }

    // MARK: - Message Row

    @ViewBuilder
    private func messageRow(_ message: ChatMessage, copyText: String?) -> some View {
        if message.role == "reasoning" {
            ReasoningRow(text: message.text, isLive: message.id == chat.reasoningID)
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

        draft = ""
        composerIsFocused = false
        chat.send(text)
    }

    /// Something is on its way but no row shows it yet. A running tool row has its own spinner.
    private var showsWaitingIndicator: Bool {
        guard chat.isGenerating, chat.streamingID == nil, chat.reasoningID == nil else { return false }
        return !(showToolCalls && chat.messages.last?.tool?.isDone == false)
    }

    // MARK: - Hermes

    /// A new chat opens ready to type. The short wait lets the push transition settle,
    /// since focus set mid-animation is dropped and the keyboard never appears.
    private func focusComposerForNewChat() async {
        guard sessionKey == nil, chat.messages.isEmpty else { return }
        try? await Task.sleep(for: .milliseconds(450))
        // Recheck: a message sent during the wait already cleared focus on purpose.
        guard !Task.isCancelled, chat.messages.isEmpty, !chat.isGenerating else { return }
        composerIsFocused = true
    }
}

#Preview {
    ChatInterfaceView()
}
