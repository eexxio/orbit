import SwiftUI
import GameController

struct IPadWorkspace: View {
    let initialWindow: ChatWindow?

    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.openWindow) private var openWindow
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var columns: NavigationSplitViewVisibility = .all
    @State private var compact: [Page] = []
    @State private var isCompact = false
    @State private var selection: ChatPresentation?
    @State private var saved: [String: ChatPresentation] = [:]
    @State private var titles: [String: String] = [:]
    @State private var unsent: ChatPresentation?
    @State private var search = ""
    @State private var showSettings = false
    @State private var showShortcuts = false
    @State private var replaceDraft = false
    @State private var unavailable = false
    @State private var didRestore = false
    @State private var observedProfile: String?
    @State private var window = WorkspaceWindowReference()
    @State private var hold = CommandHold()
    @State private var listModal = false
    @FocusState private var searchFocused: Bool

    @SceneStorage("workspace.savedChat") private var savedChat: String?
    @SceneStorage("workspace.savedAccount") private var savedAccount: String?
    @SceneStorage("workspace.savedProfile") private var savedProfile: String?
    @SceneStorage("workspace.initialized") private var initialized = false
    @SceneStorage("workspace.sidebarVisible") private var sidebarVisible = true
    @SceneStorage("workspace.compactDetail") private var compactDetail = false

    private enum Page: Hashable { case chat }
    private var client: HermesClient { HermesClient.shared }
    private var account: String { client.cache.accountScope }
    private var selectedID: String? { selection?.chat.key }
    private var selectedTitle: String? {
        guard let selectedID else { return nil }
        return client.sessions.first { $0.id == selectedID }?.title ?? titles[selectedID]
    }
    private var detailVisible: Bool { selection != nil && (!isCompact || !compact.isEmpty) }
    private var modal: Bool { showSettings || showShortcuts || replaceDraft || listModal }
    private var showHoldPanel: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-orbit-show-command-panel") && detailVisible { return true }
        #endif
        return hold.visible && window.value?.isKeyWindow == true && !modal
    }

    private var layout: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let sidebarWidth: CGFloat = width < 900 ? 260 : width < 1100 ? 292 : 320
            let narrow = sizeClass == .compact || width < (typeSize.isAccessibilitySize ? 900 : 720)
                || width - sidebarWidth < (typeSize.isAccessibilitySize ? 560 : 440)
            Group {
                if narrow {
                    NavigationStack(path: $compact) {
                        chatList
                            .navigationDestination(for: Page.self) { _ in detail(actions: true) }
                    }
                } else {
                    NavigationSplitView(columnVisibility: $columns) {
                        chatList.navigationSplitViewColumnWidth(sidebarWidth)
                    } detail: {
                        detail(actions: columns == .detailOnly)
                    }
                    .navigationSplitViewStyle(.balanced)
                }
            }
            .onChange(of: narrow, initial: true) { wasNarrow, nowNarrow in
                if wasNarrow != nowNarrow && nowNarrow {
                    setCompactDetail(selection != nil && !searchFocused)
                }
                isCompact = nowNarrow
            }
        }
    }

    var body: some View {
        keyboardAwareLayout
        .background { ChatShortcutBindings(actions: windowActions) }
        .focusedSceneValue(\.chatWindowActions, windowActions)
        .onAppear { columns = sidebarVisible ? .all : .detailOnly; restoreIfReady() }
        .task { await client.connectWorkspaceIfNeeded() }
        .onChange(of: columns) { _, value in
            if !isCompact { sidebarVisible = value != .detailOnly }
        }
        .onChange(of: compact) { _, path in compactDetail = !path.isEmpty }
        .onChange(of: selectedID) { _, id in
            if let id, let selection {
                saved[id] = selection
                if unsent === selection { unsent = nil }
            }
            if didRestore { persist(id) }
        }
        .onChange(of: unsent?.chat.key) { _, id in
            if let id, let unsent { saved[id] = unsent; self.unsent = nil }
        }
        .onChange(of: client.state, connectionChanged)
        .onChange(of: client.profile) { _, profile in
            if let observedProfile, observedProfile != profile { resetScope() }
            observedProfile = profile
        }
        .onChange(of: account) { resetScope() }
        .onChange(of: client.deletedSessionKeys) { _, deleted in
            for id in deleted {
                saved[id] = nil
                titles[id] = nil
            }
            if let selectedID, deleted.contains(selectedID) {
                selection = nil
                setCompactDetail(false)
                unavailable = true
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView().presentationDetents([.large]).presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showShortcuts) {
            ChatShortcutSheet(available: allows)
        }
        .alert("Replace Unsent Draft?", isPresented: $replaceDraft) {
            Button("Cancel", role: .cancel) {}
            Button("Start New Chat", role: .destructive, action: makeDraft)
        } message: {
            Text("Starting a new chat discards this unsent draft.")
        }
        .background {
            WorkspaceWindowReader { window.value = $0 }
        }
    }

    private var windowActions: ChatWindowActions {
        ChatWindowActions(available: { !modal && allows($0) }, label: shortcutTitle, perform: perform)
    }

    private var keyboardAwareLayout: some View {
        layout
            .overlay {
                if showHoldPanel {
                    CommandHoldPanel(available: allows).transition(.opacity)
                }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.12), value: showHoldPanel)
            .onAppear { HardwareKeyboardEvents.observeKeyboard() }
            .onReceive(NotificationCenter.default.publisher(for: .GCKeyboardDidConnect)) { _ in
                hold.reset()
                HardwareKeyboardEvents.observeKeyboard()
            }
            .onReceive(NotificationCenter.default.publisher(for: .GCKeyboardDidDisconnect)) { _ in hold.reset() }
            .onReceive(NotificationCenter.default.publisher(for: UIWindow.didResignKeyNotification)) { note in
                if note.object as? UIWindow === window.value { hold.hide() }
            }
            .onReceive(NotificationCenter.default.publisher(for: HardwareKeyboardEvents.changed)) { note in
                guard let key = note.userInfo?["key"] as? GCKeyCode,
                      let pressed = note.userInfo?["pressed"] as? Bool else { return }
                hold.update(key, pressed: pressed) { window.value?.isKeyWindow == true && !modal }
            }
            .onChange(of: modal) { if modal { hold.hide() } }
    }

    private func connectionChanged(_ old: HermesClient.State, _ state: HermesClient.State) {
        if state == .disconnected && didRestore { resetScope() }
        restoreIfReady()
    }

    private var chatList: some View {
        ChatListView(workspace: WorkspaceListContext(
            search: $search, searchFocus: $searchFocused, selectedID: selectedID,
            select: select, newChat: requestNewChat,
            openChat: supportsMultipleWindows ? { open($0.id) } : nil,
            settings: { showSettings = true }, menu: { workspaceMenu(detail: false) },
            unavailableNotice: unavailable && isCompact, modal: $listModal
        ))
    }

    private func detail(actions: Bool) -> some View {
        Group {
            if let selection {
                ChatInterfaceView(sessionKey: selectedID, presentation: selection)
                    .id(selection.id)
                    .navigationTitle(selectedTitle ?? (selectedID == nil ? "New Chat" : "Chat"))
            } else {
                idleDetail
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if actions {
                ToolbarItem(placement: .topBarTrailing) { workspaceMenu(detail: true) }
            }
        }
        .animation(reduceMotion || isCompact ? nil : .easeInOut(duration: 0.15), value: selection?.id)
    }

    private var idleTitle: LocalizedStringKey {
        if unavailable { return "Chat Unavailable" }
        if !client.isConfigured { return "Connect to Hermes" }
        if client.didLoadSessions && client.state == .connected && client.sessions.isEmpty { return "No Chats Yet" }
        return "No Chat Selected"
    }

    private var idleHelp: LocalizedStringKey {
        if unavailable { return "This chat is no longer available." }
        if !client.isConfigured { return "Set up your Hermes server to start chatting." }
        if client.didLoadSessions && client.state == .connected && client.sessions.isEmpty { return "Start a new chat with Hermes." }
        return columns == .detailOnly
            ? "Show the sidebar to choose a chat, or start a new one."
            : "Choose a chat from the sidebar or start a new one."
    }

    private var idleDetail: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 8) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 44)).foregroundStyle(.secondary)
                        .padding(.bottom, 4).accessibilityHidden(true)
                    Text(idleTitle)
                        .font(.title2.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text(idleHelp).foregroundStyle(.secondary)
                    Button(client.isConfigured ? "New Chat" : "Open Settings") {
                        if client.isConfigured { requestNewChat() } else { showSettings = true }
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .padding(.top, 12)
                    if columns == .detailOnly && !isCompact {
                        Button("Show Sidebar") { columns = .all }.frame(minHeight: 44)
                    }
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
                .padding(24)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
        }
        .background(Color(uiColor: .systemBackground))
        .accessibilityIdentifier("chats.detail.placeholder")
    }

    private func workspaceMenu(detail: Bool) -> WorkspaceActionsMenu {
        WorkspaceActionsMenu(
            detail: detail, canStart: client.isConfigured, canResume: unsent?.hasDraft == true && unsent !== selection,
            canOpenChat: allows(.openChat), canOpenWindow: supportsMultipleWindows,
            onNew: requestNewChat, onResume: resumeDraft, onOpenChat: { open(selectedID) },
            onNewWindow: { open(nil) }, onRefresh: { Task { await client.refreshSessions() } },
            onSettings: { showSettings = true }, onHelp: { showShortcuts = true }
        )
    }

    private func restoreIfReady() {
        guard !didRestore, client.state == .connected || !client.isConfigured || isFailed else { return }
        didRestore = true
        observedProfile = client.profile
        defer { initialized = true }
        let id = initialized ? savedChat : initialWindow?.sessionID
        let savedScope = initialized ? savedAccount : initialWindow?.account
        let profile = initialized ? savedProfile : initialWindow?.profile
        guard savedScope == account, profile == client.profile, let id else { persist(nil); return }
        select(id, showDetail: !initialized || compactDetail)
    }

    private var isFailed: Bool {
        if case .failed = client.state { return true }
        return false
    }

    private func persist(_ id: String?) {
        savedChat = id
        savedAccount = id == nil ? nil : account
        savedProfile = id == nil ? nil : client.profile
    }

    private func resetScope() {
        selection = nil
        unsent = nil
        saved.removeAll()
        titles.removeAll()
        search = ""
        searchFocused = false
        replaceDraft = false
        showShortcuts = false
        unavailable = false
        persist(nil)
        setCompactDetail(false)
    }

    private func select(_ session: HermesSession) {
        titles[session.id] = session.title
        select(session.id, showDetail: true)
    }

    private func select(_ id: String, showDetail: Bool) {
        guard !client.deletedSessionKeys.contains(id) else { return }
        let chat = saved[id] ?? ChatPresentation(sessionKey: id)
        saved[id] = chat
        unavailable = false
        searchFocused = false
        selection = chat
        setCompactDetail(showDetail)
    }

    private func setCompactDetail(_ detail: Bool) { compact = detail ? [.chat] : [] }

    private func requestNewChat() {
        guard client.isConfigured else { return }
        if unsent?.hasDraft == true { replaceDraft = true }
        else { makeDraft() }
    }

    private func makeDraft() {
        unsent = ChatPresentation(sessionKey: nil)
        resumeDraft()
    }

    private func resumeDraft() {
        guard let unsent else { return }
        unavailable = false
        searchFocused = false
        selection = unsent
        setCompactDetail(true)
        unsent.focusRequest += 1
    }

    private func open(_ id: String?) {
        guard supportsMultipleWindows, id.map({ !client.pendingDeletes.contains($0) }) ?? true else { return }
        openWindow(value: ChatWindow(sessionID: id, account: id == nil ? nil : account,
                                    profile: id == nil ? nil : client.profile))
    }

    private func shortcutTitle(_ shortcut: ChatShortcut) -> LocalizedStringKey {
        guard shortcut == .toggleSidebar else { return shortcut.title }
        if isCompact { return compact.isEmpty ? "Show Chat" : "Show Chats" }
        return columns == .detailOnly ? "Show Sidebar" : "Hide Sidebar"
    }

    private func allows(_ shortcut: ChatShortcut) -> Bool {
        switch shortcut {
        case .newChat: client.isConfigured
        case .newWindow: supportsMultipleWindows
        case .openChat: supportsMultipleWindows && selectedID != nil && selection?.isDeleting == false
        case .toggleSidebar: !isCompact || selection != nil
        case .focusComposer: detailVisible && selection?.isDeleting == false
        case .send: detailVisible && selection?.composerFocused == true && selection?.canSend == true && !markedText
        case .stop: detailVisible && selection?.chat.isGenerating == true && selection?.isDeleting == false
        default: true
        }
    }

    private var markedText: Bool {
        (window.value?.firstResponderView as? UITextInput)?.markedTextRange != nil
    }

    private func perform(_ shortcut: ChatShortcut) {
        guard !modal, allows(shortcut) else { return }
        switch shortcut {
        case .newChat: requestNewChat()
        case .newWindow: open(nil)
        case .openChat: open(selectedID)
        case .toggleSidebar:
            if isCompact { setCompactDetail(compact.isEmpty) }
            else { columns = columns == .detailOnly ? .all : .detailOnly }
        case .findChat:
            columns = .all
            setCompactDetail(false)
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(250))
                if !modal { searchFocused = true }
            }
        case .focusComposer: selection?.focusRequest += 1
        case .send: selection?.sendRequest += 1
        case .stop: selection?.chat.stop()
        case .settings: showSettings = true
        case .showShortcuts: showShortcuts = true
        }
    }
}

struct WorkspaceActionsMenu: View {
    var detail: Bool
    var canStart: Bool
    var canResume: Bool
    var canOpenChat: Bool
    var canOpenWindow: Bool
    var onNew: () -> Void
    var onResume: () -> Void
    var onOpenChat: () -> Void
    var onNewWindow: () -> Void
    var onRefresh: () -> Void
    var onSettings: () -> Void
    var onHelp: () -> Void

    var body: some View {
        Menu {
            if detail { Button("New Chat", systemImage: "square.and.pencil", action: onNew).disabled(!canStart) }
            if canResume { Button("Resume Draft", systemImage: "square.and.pencil", action: onResume) }
            if detail && canOpenChat { Button("Open Chat in New Window", systemImage: "rectangle.on.rectangle", action: onOpenChat) }
            if canOpenWindow { Button("New Window", systemImage: "macwindow.badge.plus", action: onNewWindow) }
            if detail { Button("Settings", systemImage: "gearshape", action: onSettings) }
            else { Button("Refresh Chats", systemImage: "arrow.clockwise", action: onRefresh) }
            Button("Keyboard Shortcuts", systemImage: "keyboard", action: onHelp)
                .accessibilityIdentifier("chats.shortcuts")
        } label: {
            Label("Workspace Actions", systemImage: "ellipsis.circle").labelStyle(.iconOnly)
                .frame(minWidth: 44, minHeight: 44)
        }
        .accessibilityIdentifier("chats.more")
    }
}
