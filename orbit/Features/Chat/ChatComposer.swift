import SwiftUI

struct ChatComposer<Content: View>: View {
    @ViewBuilder var content: Content
    let chat: LiveChat
    let isNewChat: Bool
    let dismissSuggestions: Int
    @AppStorage(AppearanceKey.accent) private var accent = Accent.mono
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var draft = ""
    @State private var focused = false
    @State private var showPicker = false
    @State private var selected: HermesCommand?
    @State private var editingSnippet: PromptSnippet?
    @State private var showLibrary = false
    @State private var restorePicker = false
    @State private var restoreFocus = false
    @State private var result: SlashResult?
    @State private var stopCount = 0
    @State private var catalog = HermesCommandCatalog.fallback
    @State private var running: String?
    @State private var commandError: String?
    @State private var requestID = UUID()
    @State private var draftRevision = UUID()
    private var catalogScope: String {
        let client = HermesClient.shared
        return client.address + "\n" + client.profile + "\n" + String(describing: client.state)
    }
    private var store: PromptSnippetStore { HermesClient.shared.snippetStore }

    private var bottomBar: some View {
        VStack(spacing: 6) {
            if let running {
                Text("Running /\(running)…").font(.footnote).foregroundStyle(.secondary)
                    .accessibilityIdentifier("slash.running")
            }
            if let commandError {
                Text(commandError).font(.footnote).foregroundStyle(.secondary)
                    .accessibilityIdentifier("slash.error")
            }
            if let selected {
                HStack {
                    Text(chat.isGenerating ? "Run when the reply ends" : "Run /\(selected.name)")
                        .accessibilityIdentifier("slash.armed")
                    Spacer()
                    Button("Use as message") { self.selected = nil; showPicker = false }
                        .accessibilityIdentifier("slash.useAsMessage")
                }
                .font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 20)
            }
            composer
        }
    }

    var body: some View {
        content
        .safeAreaInset(edge: .bottom, spacing: 0) {
            bottomBar.anchorPreference(key: ComposerBounds.self, value: .bounds) { $0 }
        }
        .overlayPreferenceValue(ComposerBounds.self) { anchor in
            GeometryReader { proxy in
                if let anchor, showPicker && focused {
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        SlashCommandMenu(query: String(draft.dropFirst()), commands: catalog.commands, isFallback: catalog.isFallback,
                                         maximumHeight: min(320, max(140, proxy[anchor].minY - 8)),
                                         unavailable: unavailable, dismiss: { showPicker = false },
                                         selectSnippet: insert, selectCommand: arm, manage: manage)
                    }
                    .frame(height: max(0, proxy[anchor].minY - 8))
                    .transition(.opacity.combined(with: .offset(y: reduceMotion ? 0 : 4)))
                }
            }
        }
        .animation(.easeOut(duration: 0.16), value: showPicker)
        .sheet(item: $editingSnippet, onDismiss: restoreAfterManagement) { SnippetEditor(snippet: $0) }
        .sheet(isPresented: $showLibrary, onDismiss: restoreAfterManagement) {
            NavigationStack {
                PromptSnippetsView().toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showLibrary = false }.accessibilityIdentifier("snippets.done")
                    }
                }
            }
        }
        .sheet(item: $result, onDismiss: { focused = true }) { SlashResultView(result: $0) }
        .onChange(of: focused) { _, value in if !value { showPicker = false } }
        .onDisappear { showPicker = false; requestID = UUID(); running = nil }
        .task(id: catalogScope) {
            requestID = UUID()
            running = nil
            commandError = nil
            selected = nil
            catalog = .fallback
            let scope = catalogScope
            let loaded = await chat.commands()
            guard !Task.isCancelled, scope == catalogScope else { return }
            catalog = loaded
        }
        .onChange(of: dismissSuggestions) { showPicker = false }
        .task {
            guard isNewChat, chat.messages.isEmpty else { return }
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled, chat.messages.isEmpty, !chat.isGenerating else { return }
            focused = true
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            ComposerTextView(text: $draft, isFocused: $focused) { eligible in
                draftRevision = UUID()
                selected = nil
                commandError = nil
                showPicker = eligible
            } selectionChanged: { eligible in
                if !eligible { showPicker = false }
            } dismissSuggestions: { showPicker = false }
                .padding(.vertical, 11)
                .accessibilityAction(named: "Show suggestions") {
                    if selected == nil, ComposerTextView.isTrigger(draft) { showPicker = true }
                }

            Button {
                if chat.isGenerating {
                    stopCount += 1
                    chat.stop()
                    AccessibilityNotification.Announcement("Reply stopped").post()
                } else {
                    submit()
                }
            } label: {
                Image(systemName: chat.isGenerating ? "stop.circle.fill" : "arrow.up.circle.fill")
                    .resizable().scaledToFit().frame(width: 30, height: 30)
                    .contentTransition(.symbolEffect(.replace.downUp))
            }
            .tint(accent.color).disabled(!chat.isGenerating && !canSubmit).animation(.default, value: canSubmit)
            .animation(.snappy(duration: 0.2), value: chat.isGenerating)
            .sensoryFeedback(.impact(weight: .medium), trigger: stopCount)
            .accessibilityLabel(chat.isGenerating ? "Stop reply" : selected == nil ? "Send" : "Run command")
            .accessibilityIdentifier(chat.isGenerating ? "chat.stop" : "chat.send")
            .keyboardShortcut(chat.isGenerating ? KeyboardShortcut(".", modifiers: .command) : nil)
            .padding(.bottom, 7)
        }
        .padding(.leading, 16).padding(.trailing, 7).frame(minHeight: 44)
        .frame(maxWidth: !focused && draft.isEmpty ? 240 : .infinity)
        .contentShape(.rect).onTapGesture { focused = true }
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 22))
        .padding(.horizontal, 16).padding(.bottom, 8)
    }

    private var canSubmit: Bool {
        running == nil && !chat.isGenerating && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (selected.map { unavailable($0) == nil } ?? true)
    }

    private func unavailable(_ command: HermesCommand) -> String? {
        guard !command.isLocal else { return nil }
        guard HermesClient.shared.state == .connected else { return "Connect to use Hermes commands" }
        guard chat.key != nil else { return "Send a message first" }
        return nil
    }

    private func insert(_ snippet: PromptSnippet) {
        draftRevision = UUID()
        commandError = nil
        draft = snippet.body
        selected = nil
        showPicker = false
        focused = true
        UISelectionFeedbackGenerator().selectionChanged()
        UIAccessibility.post(notification: .announcement, argument: "Snippet inserted")
    }

    private func arm(_ command: HermesCommand) {
        draftRevision = UUID()
        commandError = nil
        draft = "/\(command.name)"
        selected = command
        showPicker = false
        focused = true
        UISelectionFeedbackGenerator().selectionChanged()
        UIAccessibility.post(notification: .announcement, argument: "Slash \(command.name) selected. Run to view results")
    }

    private func manage() {
        restoreFocus = focused
        restorePicker = showPicker
        showPicker = false
        if store.snippets.isEmpty { editingSnippet = PromptSnippet(name: "", body: "") }
        else { showLibrary = true }
    }

    private func restoreAfterManagement() {
        focused = restoreFocus
        showPicker = restorePicker && ComposerTextView.isTrigger(draft)
    }

    private func run(_ command: HermesCommand) {
        let token = UUID()
        requestID = token
        let scope = catalogScope
        let originalDraft = draft
        let revision = draftRevision
        running = command.name
        commandError = nil
        showPicker = false
        Task {
            do {
                let reply = try await chat.execute(command)
                guard requestID == token, catalogScope == scope else { return }
                running = nil
                guard draftRevision == revision, selected?.name == command.name, draft == originalDraft else { return }
                result = SlashResult(title: "/\(command.name)", output: reply["output"].text ?? "",
                                     warning: reply["warning"].text)
                selected = nil
                draft = ""
            } catch {
                guard requestID == token, catalogScope == scope else { return }
                running = nil
                guard draftRevision == revision, selected?.name == command.name, draft == originalDraft else { return }
                let unsupported = (error as? HermesRPCError)?.isUnsupported == true
                commandError = unsupported ? "This server doesn't support /\(command.name)" : "Couldn't run /\(command.name). Try again."
            }
        }
    }

    private func submit() {
        guard canSubmit else { return }
        if let selected {
            guard selected.isLocal else {
                run(selected)
                return
            }
            result = SlashResult(title: "/help", output: "Type / to find shortcuts. Select a saved snippet to insert its full prompt, then edit and Send.\n\nSelect a command, then Run to view its result. Use as message sends the text normally.\n\n" + HermesCommand.fallback.map { "/\($0.name) — \($0.summary)" }.joined(separator: "\n"))
            self.selected = nil
            draft = ""
            showPicker = false
        } else {
            let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            draft = ""
            showPicker = false
            focused = false
            chat.send(text)
        }
    }
}

private struct ComposerBounds: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) { value = nextValue() ?? value }
}
