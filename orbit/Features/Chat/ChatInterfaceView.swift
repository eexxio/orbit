
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
    @State private var isFollowingBottom = true
    @State private var isUserScrolling = false
    @State private var draft = ""

    @FocusState private var composerIsFocused: Bool

    private let columnWidth: CGFloat = 720

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
                LazyVStack(alignment: .leading, spacing: 0) {
                    let copies = replyCopies
                    let completedID = chat.replyState == .completed
                        ? chat.messages.reversed().prefix(while: { !$0.isUser }).first(where: { $0.role == "assistant" })?.id
                        : nil
                    // Hidden tool calls stay in `messages`, so the cache and the toggle keep them.
                    let messages = showToolCalls ? chat.messages : chat.messages.filter { $0.tool == nil }
                    ForEach(messages.enumerated(), id: \.element.id) { index, message in
                        let previous = index > 0 ? messages[index - 1] : nil
                        messageRow(message, copyText: copies[message.id], isCompletedReply: message.id == completedID)
                            .padding(.top, transcriptGap(before: message, after: previous))
                    }

                    replyStatus
                }
                .frame(maxWidth: columnWidth)
                .padding(.horizontal, 18)
                .padding(.top, 8)
                .padding(.bottom, 16)
                // A conversation stacks up from the composer: a short one sits just above
                // the input field instead of hanging from the navigation bar and leaving a
                // well of empty space above it.
                .frame(maxWidth: .infinity, minHeight: proxy.size.height, alignment: .bottom)
            }
            // An existing chat opens at its newest message, however long its history is.
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .scrollDismissesKeyboard(.interactively)
            .scrollPosition($scrollPosition)
            .onScrollGeometryChange(for: CGFloat.self) { bottomOffset(in: $0) } action: { old, new in
                if abs(new - old) > 0.5 { pinIfFollowing() }
            }
            .onScrollGeometryChange(for: Bool.self) { isNearBottom(in: $0) } action: { _, nearBottom in
                if isUserScrolling && nearBottom { isFollowingBottom = true }
            }
            .onScrollPhaseChange { old, new, context in
                isUserScrolling = new == .tracking || new == .interacting || new == .decelerating
                guard new == .idle else { return }
                if old == .interacting || old == .decelerating {
                    isFollowingBottom = isNearBottom(in: context.geometry)
                }
                if old != .animating { pinIfFollowing() }
            }
            .onAppear { pinIfFollowing() }
            .onChange(of: scrollToken) { pinIfFollowing() }
            .overlay(alignment: .bottom) {
                if !isFollowingBottom {
                    JumpToLatestButton(action: followLatest)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .frame(maxWidth: columnWidth)
                        .padding(.horizontal, 18)
                        .padding(.bottom, 8)
                }
            }
        }
    }

    private func bottomOffset(in geometry: ScrollGeometry) -> CGFloat {
        geometry.contentSize.height + geometry.contentInsets.bottom - geometry.containerSize.height
    }

    private func isNearBottom(in geometry: ScrollGeometry) -> Bool {
        geometry.contentSize.height - geometry.visibleRect.maxY <= 40
    }

    private func followLatest() {
        isFollowingBottom = true
        scrollPosition.scrollTo(edge: .bottom)
    }

    private func pinIfFollowing() {
        // A lazy stack may not have realized its final row yet, so scroll to the edge, not an ID.
        guard isFollowingBottom, !isUserScrolling else { return }
        scrollPosition.scrollTo(edge: .bottom)
    }

    private func transcriptGap(before message: ChatMessage, after previous: ChatMessage?) -> CGFloat {
        guard let previous else { return 0 }
        if message.isUser || previous.isUser { return 24 }
        if (message.tool != nil || message.role == "reasoning") &&
            (previous.tool != nil || previous.role == "reasoning") { return 8 }
        return 12
    }

    /// Changes whenever the newest content changes, so the view follows it to the bottom.
    private var scrollToken: String {
        "\(chat.messages.count)|\(chat.messages.last?.text.count ?? 0)|\(chat.replyState)"
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
        if message.role == "reasoning" {
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
            VStack(alignment: .leading, spacing: copyText == nil ? 12 : 0) {
                // Full block-level Markdown: headings, lists, code blocks, quotes, tables.
                Markdown(message.text)
                    .markdownTheme(.basic)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if copyText != nil || message.rate != nil {
                    HStack(spacing: 0) {
                        if let copyText {
                            Button {
                                UIPasteboard.general.string = copyText
                            } label: {
                                Image(systemName: "doc.on.doc")
                                    .frame(width: 44, height: 44, alignment: .leading)
                                    .contentShape(.rect)
                            }
                            .accessibilityLabel("Copy reply")
                            .accessibilityIdentifier("chat.reply.completed", isEnabled: isCompletedReply)
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
        let shape = RoundedRectangle(cornerRadius: 22)
        return HStack(alignment: .bottom, spacing: 8) {
            // Grows with its text up to six lines, then scrolls.
            TextField("Ask anything", text: $draft, axis: .vertical)
                .focused($composerIsFocused)
                .lineLimit(1...6)
                .padding(.vertical, 11)
                .accessibilityIdentifier("chat.composer")

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
            .accessibilityIdentifier("chat.send")
            .padding(.bottom, 7)
        }
        .padding(.leading, 16)
        .padding(.trailing, 7)
        .frame(minHeight: 44)
        // At rest the bar narrows toward the center; focusing it expands to the conversation width.
        .frame(maxWidth: composerIsCollapsed ? 240 : columnWidth)
        .contentShape(.rect)
        .onTapGesture { composerIsFocused = true }
        .background(Color(uiColor: .systemBackground).opacity(isFollowingBottom ? 0 : 1), in: shape)
        .glassEffect(.regular.interactive(), in: shape)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .animation(.spring(duration: 0.4, bounce: 0.2), value: composerIsCollapsed)
    }

    /// Collapsed while unfocused, unless there is a draft that would get squeezed.
    private var composerIsCollapsed: Bool {
        !composerIsFocused && draft.isEmpty
    }

    private var canSend: Bool {
        !chat.isGenerating && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Send Message

    private func sendMessage() {
        let text = draft.trimmingCharacters(
            in: .whitespacesAndNewlines
        )

        guard canSend else { return }

        draft = ""
        composerIsFocused = false
        followLatest()
        chat.send(text)
    }

    @ViewBuilder
    private var replyStatus: some View {
        switch chat.replyState {
        case .idle, .completed:
            EmptyView()
        case .waiting where !showsWaitingIndicator:
            EmptyView()
        default:
            let previous = chat.messages.last { showToolCalls || $0.tool == nil }
            replyStatusRow
                .padding(.top, previous?.isUser == true ? 24 : 12)
        }
    }

    @ViewBuilder
    private var replyStatusRow: some View {
        switch chat.replyState {
        case .waiting, .streaming:
            ReplyActivityRow(
                isStreaming: chat.replyState == .streaming
            )
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
