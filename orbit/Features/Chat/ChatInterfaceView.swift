
import SwiftUI
import MarkdownUI

struct ChatInterfaceView: View {

    /// The Hermes session this chat shows; nil starts a new one on the first message.
    let sessionKey: String?
    private let isWorkspace: Bool

    init(sessionKey: String? = nil, presentation: ChatPresentation? = nil) {
        self.sessionKey = sessionKey
        self.isWorkspace = presentation != nil
        _presentation = State(initialValue: presentation ?? ChatPresentation(sessionKey: sessionKey))
    }

    @AppStorage(AppearanceKey.accent) private var accent = Accent.mono
    @AppStorage(AppearanceKey.showToolCalls) private var showToolCalls = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var presentation: ChatPresentation
    @State private var viewerID = UUID()
    @State private var stopCount = 0
    @State private var isUserScrolling = false
    @State private var availableHeight: CGFloat = 600
    @ScaledMetric(relativeTo: .body) private var tabletBodySize = 20.0

    @FocusState private var composerIsFocused: Bool
    private var chat: LiveChat { presentation.chat }
    private var draft: String { presentation.draft }

    var body: some View {
        Group {
            if isWorkspace {
                content
            } else {
                NavigationStack { content }
            }
        }
        .task { if !isWorkspace { await focusComposerForNewChat() } }
        .task(id: presentation.focusRequest) {
            guard isWorkspace, presentation.focusRequest != 0 else { return }
            try? await Task.sleep(for: .milliseconds(250))
            if !Task.isCancelled { composerIsFocused = true; presentation.focusRequest = 0 }
        }
        .onChange(of: presentation.sendRequest) {
            if isWorkspace, composerIsFocused, !presentation.hasMarkedText { sendMessage() }
        }
        .onChange(of: composerIsFocused) { _, focused in presentation.composerFocused = focused }
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { availableHeight = $0 }
        .onAppear {
            chat.addViewer(viewerID)
        }
        .onDisappear {
            presentation.composerFocused = false
            chat.removeViewer(viewerID)
        }
    }

    private var content: some View {
        Group {
            if chat.isLoadingHistory && chat.messages.isEmpty {
                loadingState
            } else if let error = chat.historyError, chat.messages.isEmpty {
                ContentUnavailableView {
                    Label("Couldn't Load Conversation", systemImage: "exclamationmark.bubble")
                } description: {
                    Text(error)
                } actions: {
                    Button("Retry") { Task { await chat.loadHistory() } }
                }
            } else if chat.messages.isEmpty {
                emptyState
            } else {
                conversation
            }
        }
        .background(Color(uiColor: .systemBackground))
        .safeAreaInset(edge: .bottom, spacing: 0) { composer }
        .safeAreaInset(edge: .top, spacing: 0) {
            if isWorkspace && presentation.isDeleting {
                Label("Deleting chat…", systemImage: "trash").font(.subheadline).padding(8)
            }
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
                .lineLimit(isWorkspace ? nil : 1)
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
                LazyVStack(alignment: .leading, spacing: isWorkspace ? 0 : 24) {
                    let copies = replyCopies
                    let completedID = chat.replyState == .completed
                        ? chat.messages.reversed().prefix(while: { !$0.isUser }).first(where: { $0.role == "assistant" })?.id
                        : nil
                    // Hidden tool calls stay in `messages`, so the cache and the toggle keep them.
                    let messages = showToolCalls ? chat.messages : chat.messages.filter { $0.tool == nil }
                    ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                        messageRow(message, copyText: copies[message.id], isCompletedReply: message.id == completedID)
                            .padding(.top, isWorkspace ? transcriptGap(messages, at: index) : 0)
                            .id(message.id)
                    }

                    replyStatus.padding(.top, isWorkspace ? 12 : 0)
                }
                .scrollTargetLayout()
                .frame(width: isWorkspace ? min(720, max(0, proxy.size.width - 48)) : nil)
                .padding(.horizontal, isWorkspace ? 24 : 18)
                .padding(.top, 8)
                .padding(.bottom, 16)
                // A conversation stacks up from the composer: a short one sits just above
                // the input field instead of hanging from the navigation bar and leaving a
                // well of empty space above it.
                .frame(maxWidth: .infinity, minHeight: proxy.size.height, alignment: .bottom)
            }
            // An existing chat opens at its newest message, however long its history is.
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .defaultScrollAnchor(isWorkspace ? nil : .bottom, for: .sizeChanges)
            .scrollDismissesKeyboard(.interactively)
            .scrollPosition($presentation.scrollPosition)
            // The rows of a lazy stack report their real height a frame or two after they
            // appear, and the keyboard (or a taller composer) grows the bottom inset. Both
            // push the newest message below the composer unless the view follows them down.
            .onScrollGeometryChange(for: ScrollGeometry.self) { $0 } action: { old, new in
                let grewContent = new.contentSize.height > old.contentSize.height + 0.5
                let grewInset = new.contentInsets.bottom > old.contentInsets.bottom + 0.5
                guard grewContent || grewInset else { return }
                pinToBottom()
            }
            .onScrollPhaseChange { _, phase, context in
                guard isWorkspace else { return }
                if phase == .idle && isUserScrolling {
                    presentation.followsLatest = context.geometry.contentSize.height - context.geometry.visibleRect.maxY <= 40
                    presentation.scrollAnchor = presentation.scrollPosition.viewID(type: UUID.self)
                }
                isUserScrolling = phase == .tracking || phase == .interacting || phase == .decelerating
            }
            .onAppear {
                if isWorkspace, !presentation.followsLatest, let anchor = presentation.scrollAnchor {
                    presentation.scrollPosition.scrollTo(id: anchor, anchor: .top)
                } else {
                    pinToBottom()
                }
            }
            // A loaded or refreshed history, a sent message, and each streamed word.
            .onChange(of: scrollToken) { pinToBottom() }
            .overlay(alignment: .bottomTrailing) {
                if isWorkspace && !presentation.followsLatest {
                    Button {
                        presentation.followsLatest = true
                        pinToBottom()
                    } label: {
                        Label("Jump to latest", systemImage: "arrow.down")
                            .padding(.horizontal, 12).frame(minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    .padding(18)
                }
            }
        }
    }

    /// Puts the newest message directly above the composer.
    ///
    /// Scrolling to an edge rather than to a view id: on the first layout pass a lazy
    /// stack has not realized its last row yet, so an id-based scroll has nothing to aim
    /// at and the chat opens short of the bottom. The edge also keeps its position when
    /// the content grows, which is what streaming and late layout both need.
    private func pinToBottom() {
        guard !isWorkspace || presentation.followsLatest && !isUserScrolling else { return }
        presentation.scrollPosition.scrollTo(edge: .bottom)
    }

    private func transcriptGap(_ messages: [ChatMessage], at index: Int) -> CGFloat {
        guard index > 0 else { return 0 }
        let a = messages[index - 1], b = messages[index]
        if a.isUser || b.isUser { return 24 }
        if (a.tool != nil || a.role == "reasoning") && (b.tool != nil || b.role == "reasoning") { return 8 }
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
                    .font(isWorkspace ? .system(size: tabletBodySize) : .body)
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
                    .markdownTheme(isWorkspace ? .basic.text { FontSize(tabletBodySize) } : .basic)
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
        VStack(spacing: 4) {
            if isWorkspace && HermesClient.shared.state != .connected {
                Text(HermesClient.shared.state == .connecting ? "Connecting…" : "Offline")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            composerBar
        }
    }

    private var composerBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            // Grows with its text up to six lines, then scrolls.
            TextField("Ask anything", text: $presentation.draft, axis: .vertical)
                .focused($composerIsFocused)
                .onKeyPress(.escape) {
                    guard isWorkspace else { return .ignored }
                    composerIsFocused = false
                    return .handled
                }
                .font(isWorkspace ? .system(size: tabletBodySize) : .body)
                .lineLimit(1...composerLineLimit)
                .padding(.vertical, 11)
                .accessibilityIdentifier("chat.composer")

            Button(action: sendOrStop) {
                // Resizable so the circle fills exactly 30pt; a font-sized symbol
                // carries extra baseline space below it and sits off-center.
                Image(systemName: chat.isGenerating ? "stop.circle.fill" : "arrow.up.circle.fill")
                    .resizable()
                    .scaledToFit()
                    .frame(width: isWorkspace ? 34 : 30, height: isWorkspace ? 34 : 30)
                    .frame(minWidth: isWorkspace ? 44 : nil, minHeight: isWorkspace ? 44 : nil)
                    .contentShape(.rect)
                    .contentTransition(isWorkspace && reduceMotion ? .identity : .symbolEffect(.replace.downUp))
            }
            .tint(accent.color)
            .disabled(chat.isGenerating ? presentation.isDeleting : !canSend)
            .animation(isWorkspace && reduceMotion ? nil : .default, value: canSend)
            .sensoryFeedback(.impact(weight: .medium), trigger: stopCount)
            .accessibilityLabel(chat.isGenerating ? "Stop reply" : "Send")
            .accessibilityIdentifier(chat.isGenerating ? "chat.stop" : "chat.send")
            .keyboardShortcut(!isWorkspace && chat.isGenerating ? KeyboardShortcut(".", modifiers: .command) : nil)
            .padding(.bottom, isWorkspace ? 4 : 7)
        }
        .padding(.leading, 16)
        .padding(.trailing, 7)
        .frame(minHeight: isWorkspace ? 52 : 44)
        // At rest the bar narrows toward the center; focusing it spreads it full width.
        .frame(maxWidth: composerIsCollapsed ? (isWorkspace ? 336 : 240) : (isWorkspace ? 840 : .infinity))
        .contentShape(.rect)
        .onTapGesture { composerIsFocused = true }
        .modifier(ChatComposerBackground(isWorkspace: isWorkspace, reduceTransparency: reduceTransparency))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .animation(isWorkspace && reduceMotion ? nil : .spring(duration: 0.4, bounce: 0.2), value: composerIsCollapsed)
    }

    private var composerLineLimit: Int {
        isWorkspace ? min(6, max(1, Int((availableHeight * 0.4 - 22) / (tabletBodySize * 1.2)))) : 6
    }

    /// Collapsed while unfocused, unless there is a draft that would get squeezed.
    private var composerIsCollapsed: Bool {
        !composerIsFocused && draft.isEmpty
    }

    private var canSend: Bool {
        isWorkspace ? presentation.canSend : !chat.isGenerating && presentation.hasDraft
    }

    // MARK: - Send Message

    private func sendMessage() {
        let text = draft.trimmingCharacters(
            in: .whitespacesAndNewlines
        )

        guard canSend else { return }

        presentation.draft = ""
        composerIsFocused = false
        presentation.followsLatest = true
        pinToBottom()
        chat.send(text)
    }

    private func sendOrStop() {
        if chat.isGenerating {
            if !presentation.isDeleting {
                stopCount += 1
                chat.stop()
                AccessibilityNotification.Announcement("Reply stopped").post()
            }
        } else {
            sendMessage()
        }
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
        case .interrupted(let detail):
            replyIssue("Reply interrupted", detail: detail, identifier: "chat.reply.interrupted")
        case .failed(let detail):
            replyIssue("Reply failed", detail: detail, identifier: "chat.reply.failed")
        case .stopped:
            Label {
                Text("Stopped").accessibilityIdentifier("chat.reply.stopped")
            } icon: {
                Image(systemName: "stop.circle").accessibilityHidden(true)
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
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

private struct ChatComposerBackground: ViewModifier {
    let isWorkspace: Bool
    let reduceTransparency: Bool

    func body(content: Content) -> some View {
        if isWorkspace && reduceTransparency {
            content.background(Color(uiColor: .secondarySystemBackground), in: .rect(cornerRadius: 26))
        } else {
            content.glassEffect(.regular.interactive(), in: .rect(cornerRadius: isWorkspace ? 26 : 22))
        }
    }
}

#Preview {
    ChatInterfaceView()
}
