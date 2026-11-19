
import SwiftUI
import MarkdownUI

struct ChatInterfaceView: View {

    /// The Hermes session this chat shows; nil starts a new one on the first message.
    let session: HermesSession?
    let onNewChat: (String?) -> Void

    init(session: HermesSession? = nil, profile: String? = nil, onNewChat: @escaping (String?) -> Void = { _ in }) {
        self.session = session
        self.onNewChat = onNewChat
        // A chat still replying in the background comes back as it is, not reloaded.
        _chat = State(initialValue: HermesClient.shared.liveChat(for: session, profile: profile))
    }

    @AppStorage(AppearanceKey.accent) private var accent = Accent.mono
    @AppStorage(AppearanceKey.showToolCalls) private var showToolCalls = true
    @State private var chat: LiveChat
    @State private var scrollPosition = ScrollPosition()
    @State private var draft = ""
    @State private var stopCount = 0

    @FocusState private var composerIsFocused: Bool

    var body: some View {
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
            if chat.isProfileGone {
                VStack(spacing: 6) {
                    Text(HermesError.profileGone.localizedDescription)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("New chat") { onNewChat(nil) }
                }
                .padding()
            } else {
                composer
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                ChatModelTitle(chat: chat, onOpen: { composerIsFocused = false }, onNewChat: onNewChat)
            }
        }
        .task { await chat.loadHistory() }
        .task(id: chat.profile) {
            let client = HermesClient.shared
            let profile = chat.profile
            if client.profiles.isEmpty { _ = try? await client.chatProfiles() }
            if !Task.isCancelled, chat.isDraft, client.modelCatalogs[profile] == nil,
               client.profiles.first(where: { $0.name == profile })?.model == nil {
                _ = try? await client.chatModels(profile: profile, refresh: false)
            }
        }
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

        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Sit a little above center, where the eye lands, not behind the keyboard.
        .offset(y: -40)
    }

    // MARK: - Conversation

    private var conversation: some View {
        GeometryReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    let copies = replyCopies
                    let completedID = chat.replyState == .completed
                        ? chat.messages.reversed().prefix(while: { !$0.isUser }).first(where: { $0.role == "assistant" })?.id
                        : nil
                    // Hidden tool calls stay in `messages`, so the cache and the toggle keep them.
                    ForEach(showToolCalls ? chat.messages : chat.messages.filter { $0.tool == nil }) { message in
                        messageRow(message, copyText: copies[message.id], isCompletedReply: message.id == completedID)
                    }

                    replyStatus
                        .transition(.opacity)
                        .animation(.default, value: chat.replyState)
                    if let pending = chat.pendingModel {
                        ModelChangeRow(model: pending.name, pending: true)
                    }
                    if let error = chat.modelError {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("chat.modelError")
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
        "\(chat.messages.count)|\(chat.messages.last?.text.count ?? 0)|\(chat.replyState)|\(chat.pendingModel?.name ?? "")"
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
    private func messageRow(_ message: ChatMessage, copyText: String?, isCompletedReply: Bool) -> some View {
        if message.role == "model-change" {
            ModelChangeRow(model: message.text, pending: false)
        } else if message.role == "reasoning" {
            ReasoningRow(text: message.text, isLive: message.id == chat.reasoningID)
        } else if let tool = message.tool {
            ToolCallRow(tool: tool, isLive: chat.liveToolIDs.contains(message.id))
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
                            .accessibilityIdentifier(isCompletedReply ? "chat.reply.completed" : "chat.reply.copy")
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
                .accessibilityIdentifier("chat.composer")

            Button {
                if chat.isGenerating {
                    stopCount += 1
                    chat.stop()
                    AccessibilityNotification.Announcement("Reply stopped").post()
                } else {
                    sendMessage()
                }
            } label: {
                // Resizable so the circle fills exactly 30pt; a font-sized symbol
                // carries extra baseline space below it and sits off-center.
                Image(systemName: chat.isGenerating ? "stop.circle.fill" : "arrow.up.circle.fill")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 30, height: 30)
                    .contentTransition(.symbolEffect(.replace.downUp))
            }
            .tint(accent.color)
            .disabled(!chat.isGenerating && !canSend)
            .animation(.default, value: canSend)
            .animation(.snappy(duration: 0.2), value: chat.isGenerating)
            .sensoryFeedback(.impact(weight: .medium), trigger: stopCount)
            .accessibilityLabel(chat.isGenerating ? "Stop reply" : "Send")
            .accessibilityIdentifier(chat.isGenerating ? "chat.stop" : "chat.send")
            .keyboardShortcut(chat.isGenerating ? KeyboardShortcut(".", modifiers: .command) : nil)
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
        chat.canSend && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Send Message

    private func sendMessage() {
        let text = draft.trimmingCharacters(
            in: .whitespacesAndNewlines
        )

        guard canSend else { return }

        draft = ""
        composerIsFocused = false
        chat.send(text)
    }

    @ViewBuilder
    private var replyStatus: some View {
        switch chat.replyState {
        case .waiting where showsWaitingIndicator:
            HStack(spacing: 6) {
                Image(systemName: "brain")
                    .symbolEffect(.pulse)
                    .accessibilityHidden(true)
                Text("Thinking…")
                    .accessibilityIdentifier("chat.reply.waiting")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        case .streaming:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini).accessibilityHidden(true)
                Text("Replying…")
                    .accessibilityIdentifier("chat.reply.streaming")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        case .stopped:
            HStack(spacing: 6) {
                Image(systemName: "stop.circle")
                    .accessibilityHidden(true)
                Text("Stopped")
                    .accessibilityIdentifier("chat.reply.stopped")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        case .interrupted(let detail):
            replyIssue("Reply interrupted", detail: detail, identifier: "chat.reply.interrupted")
        case .failed(let detail):
            replyIssue("Reply failed", detail: detail, identifier: "chat.reply.failed")
        default:
            EmptyView()
        }
    }

    private func replyIssue(_ title: String, detail: String, identifier: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .fontWeight(.semibold)
                    .accessibilityIdentifier(identifier)
                Text(detail)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: "exclamationmark.circle")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
        }
        .font(.subheadline)
    }

    /// Something is on its way but no row shows it yet. A running tool row has its own spinner.
    private var showsWaitingIndicator: Bool {
        guard chat.reasoningID == nil else { return false }
        return !(showToolCalls && chat.messages.last?.tool?.isDone == false)
    }

    // MARK: - Hermes

    /// A new chat opens ready to type. The short wait lets the push transition settle,
    /// since focus set mid-animation is dropped and the keyboard never appears.
    private func focusComposerForNewChat() async {
        guard session == nil, chat.messages.isEmpty else { return }
        try? await Task.sleep(for: .milliseconds(450))
        // Recheck: a message sent during the wait already cleared focus on purpose.
        guard !Task.isCancelled, chat.messages.isEmpty, !chat.isGenerating else { return }
        composerIsFocused = true
    }
}

#Preview {
    ChatInterfaceView()
}
