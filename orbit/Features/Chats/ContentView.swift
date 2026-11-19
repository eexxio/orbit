import SwiftUI

struct ContentView: View {
    var window: ChatWindow? = nil

    var body: some View {
        if UIDevice.current.userInterfaceIdiom == .pad {
            IPadWorkspace(initialWindow: window)
        } else {
            NavigationStack { ChatListView() }
        }
    }
}

struct WorkspaceListContext {
    let search: Binding<String>
    let searchFocus: FocusState<Bool>.Binding
    let selectedID: String?
    let select: (HermesSession) -> Void
    let newChat: () -> Void
    let openChat: ((HermesSession) -> Void)?
    let settings: () -> Void
    let menu: () -> WorkspaceActionsMenu
    let unavailableNotice: Bool
    let modal: Binding<Bool>
}

struct ChatListView: View {
    var workspace: WorkspaceListContext? = nil
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var phoneSearch = ""
    @State private var showPhoneSettings = false
    @State private var startNewChat = false
    @State private var newChatID = UUID()
    @State private var pendingDelete: HermesSession?
    @State private var renaming: HermesSession?
    @State private var renameText = ""
    @State private var actionError: String?
    @State private var errorTitle = ""
    @State private var showLoading = false
    @State private var activeDate = Date()

    private var client: HermesClient { HermesClient.shared }
    private var query: String { workspace?.search.wrappedValue ?? phoneSearch }
    private var filtered: [HermesSession] {
        client.sessions.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }
            .sorted {
                let a = $0.lastActive ?? 0, b = $1.lastActive ?? 0
                if a != b { return a > b }
                let comparison = $0.title.localizedStandardCompare($1.title)
                return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
            }
    }

    var body: some View {
        Group {
            if let workspace {
                workspaceList(workspace)
            } else {
                rowsList
                    .navigationTitle("Chats").navigationBarTitleDisplayMode(.large)
                    .searchable(text: $phoneSearch, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search")
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button { showPhoneSettings = true } label: { Image(systemName: "gearshape") }
                                .accessibilityLabel("Settings")
                        }
                        ToolbarSpacer(.flexible, placement: .bottomBar)
                        ToolbarItem(placement: .bottomBar) {
                            newChatButton {
                                newChatID = UUID()
                                startNewChat = true
                            }
                        }
                    }
                    .navigationDestination(isPresented: $startNewChat) {
                        ChatInterfaceView().id(newChatID).navigationBarTitleDisplayMode(.inline)
                    }
            }
        }
            .task { if workspace == nil, client.isConfigured, client.state == .disconnected { await client.connect() } }
            .task(id: client.state) {
                showLoading = false
                if client.state == .connecting {
                    try? await Task.sleep(for: .seconds(1))
                    if !Task.isCancelled { showLoading = true }
                }
            }
            .onAppear { if workspace == nil, client.state == .connected { Task { await client.refreshSessions() } } }
            .onChange(of: scenePhase) { _, phase in if phase == .active { activeDate = .now } }
            .sheet(isPresented: $showPhoneSettings) {
                SettingsView().presentationDetents([.large]).presentationDragIndicator(.visible)
            }
            .alert(pendingDelete.map(deleteTitle) ?? "Delete Chat?", isPresented: Binding(
                get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }
            )) {
                if let chat = pendingDelete {
                    Button("Delete Chat", role: .destructive) {
                        perform("Delete") { try await client.deleteSession(chat) }
                        pendingDelete = nil
                    }.accessibilityIdentifier("chats.delete.confirm")
                }
                Button("Cancel", role: .cancel) { pendingDelete = nil }
            } message: {
                if let chat = pendingDelete {
                    Text(client.replyingKeys.contains(chat.id)
                         ? "\(chat.title) is still replying. Deleting stops the reply and removes the chat from \(host)."
                         : "This deletes the chat and its history from \(host). You can't undo this.")
                }
            }
            .alert("Rename Chat", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Chat name", text: Binding(get: { renameText }, set: { text in
                    renameText = String(text.replacingOccurrences(of: "\n", with: " ")
                        .replacingOccurrences(of: "\r", with: " ").prefix(100))
                }))
                    .submitLabel(.done).textInputAutocapitalization(.sentences)
                    .accessibilityIdentifier("chats.rename.field")
                Button("Cancel", role: .cancel) { renaming = nil }
                Button("Save") {
                    if let chat = renaming {
                        let title = trimmedName
                        perform("Rename") { try await client.renameSession(chat, title: title) }
                    }
                    renaming = nil
                }.disabled(trimmedName.isEmpty || trimmedName == renaming?.title)
            }
            .alert(errorTitle, isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
                Button("OK") { actionError = nil }
            } message: { Text(actionError ?? "") }
            .onChange(of: pendingDelete != nil || renaming != nil || actionError != nil) {
                workspace?.modal.wrappedValue = pendingDelete != nil || renaming != nil || actionError != nil
            }
            .onDisappear { workspace?.modal.wrappedValue = false }
    }

    private var rowsList: some View {
        TimelineView(.periodic(from: activeDate, by: 60)) { context in
            let pinned = filtered.filter(\.pinned)
            let recent = filtered.filter { !$0.pinned }
            List {
                if !pinned.isEmpty { Section("Pinned") { rows(pinned, now: context.date) } }
                if !recent.isEmpty {
                    if pinned.isEmpty && workspace == nil { rows(recent, now: context.date) }
                    else { Section("Recent") { rows(recent, now: context.date) } }
                }
            }
            .coordinateSpace(name: "chatList")
            .scrollContentBackground(.hidden)
            .background(workspace == nil ? Color(uiColor: .systemGroupedBackground) : .clear)
            .animation(workspace != nil && reduceMotion ? nil : .default, value: filtered)
            .overlay {
                if filtered.isEmpty {
                    if let workspace { workspaceEmpty(workspace) }
                    else { emptyState }
                }
            }
            .refreshable { await client.refreshSessions() }
        }
    }

    private func workspaceList(_ workspace: WorkspaceListContext) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").accessibilityHidden(true)
                TextField("Search Chats", text: workspace.search)
                    .focused(workspace.searchFocus)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onKeyPress(.escape) { workspace.searchFocus.wrappedValue = false; return .handled }
                    .accessibilityIdentifier("chats.search")
                if !query.isEmpty {
                    Button { workspace.search.wrappedValue = "" } label: {
                        Image(systemName: "xmark.circle.fill").frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear Search")
                }
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .background(Color(uiColor: .tertiarySystemFill), in: .rect(cornerRadius: 12))
            .padding(.horizontal, 12)
            .padding(.vertical, 4)

            if !client.sessions.isEmpty && isOffline {
                HStack {
                    Label("Offline", systemImage: "network.slash").foregroundStyle(.secondary)
                    Spacer()
                    Button("Retry Connection", action: retry).frame(minHeight: 44)
                }
                .font(.subheadline)
                .padding(.horizontal, 12)
            }
            if workspace.unavailableNotice {
                Label("This chat is no longer available.", systemImage: "bubble.left")
                    .font(.subheadline).padding(8)
            }

            rowsList
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            Divider()
            HStack {
                Button(action: workspace.settings) {
                    Image(systemName: "gearshape").frame(width: 44, height: 44)
                }
                .accessibilityLabel("Settings")
                Spacer()
                workspace.menu()
            }
            .font(.system(size: 20))
            .buttonStyle(.plain)
            .padding(.horizontal, 8)
        }
        .background(Color(uiColor: .secondarySystemBackground))
        .navigationTitle("Chats")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                newChatButton(workspace.newChat)
                    .disabled(!client.isConfigured)
            }
        }
    }

    @ViewBuilder
    private func workspaceEmpty(_ workspace: WorkspaceListContext) -> some View {
        ScrollView {
            if !client.sessions.isEmpty {
                ContentUnavailableView {
                    Label("No Results", systemImage: "magnifyingglass")
                } actions: {
                    Button("Clear Search") { workspace.search.wrappedValue = "" }
                }
            } else if !client.isConfigured {
                ContentUnavailableView {
                    Label("Set Up Orbit", systemImage: "network")
                } actions: {
                    Button("Open Settings", action: workspace.settings)
                }
            } else if client.state == .connecting {
                if showLoading {
                    VStack(spacing: 8) { ProgressView(); Text("Loading Chats…") }.padding()
                }
            } else if isOffline {
                ContentUnavailableView {
                    Label("Not Connected", systemImage: "network.slash")
                } actions: {
                    Button("Retry Connection", action: retry)
                    Button("Open Settings", action: workspace.settings)
                }
            } else if client.didLoadSessions {
                ContentUnavailableView {
                    Label("No Chats Yet", systemImage: "bubble.left.and.bubble.right")
                } actions: {
                    Button("New Chat", action: workspace.newChat)
                }
            }
        }
        .accessibilityIdentifier("chats.empty")
    }

    private var isOffline: Bool {
        if case .failed = client.state { return true }
        return client.state == .disconnected
    }

    private func retry() { Task { await client.connect() } }

    private func newChatButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: "square.and.pencil") }
            .accessibilityLabel("New chat").accessibilityIdentifier("chats.new")
    }

    private var trimmedName: String { renameText.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var host: String { client.baseURL?.host() ?? "the server" }

    private func rows(_ chats: [HermesSession], now: Date) -> some View {
        ForEach(chats) { chat in
            chatLink(chat, now: now)
                .swipeActions(edge: .leading, allowsFullSwipe: true) { pinButton(chat) }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    deleteButton(chat).tint(.red)
                    renameButton(chat).tint(.gray)
                }
                .contextMenu {
                    if let open = workspace?.openChat {
                        Button { open(chat) } label: {
                            Label("Open Chat in New Window", systemImage: "rectangle.on.rectangle")
                        }
                        .disabled(client.pendingDeletes.contains(chat.id))
                        .accessibilityIdentifier("chats.open-window")
                        Divider()
                    }
                    pinButton(chat)
                    renameButton(chat)
                    deleteButton(chat)
                }
        }
    }

    @ViewBuilder private func chatLink(_ chat: HermesSession, now: Date) -> some View {
        let selected = workspace?.selectedID == chat.id
        let row = ChatRow(chat: chat, isReplying: client.replyingKeys.contains(chat.id), now: now,
                          selectedInWorkspace: selected)
        if let workspace {
            Button { workspace.select(chat) } label: {
                row.padding(.horizontal, 12).padding(.vertical, 8)
                    .frame(minHeight: 56)
                    .background {
                        if selected {
                            RoundedRectangle(cornerRadius: 10)
                                .fill(.primary.opacity(contrast == .increased ? 0.16 : 0.1))
                                .overlay {
                                    if contrast == .increased {
                                        RoundedRectangle(cornerRadius: 10).strokeBorder(.primary, lineWidth: 2)
                                    }
                                }
                        }
                    }
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
        } else {
            NavigationLink {
                ChatInterfaceView(sessionKey: chat.id).navigationBarTitleDisplayMode(.inline)
            } label: { row }
        }
    }

    private func deleteTitle(_ chat: HermesSession) -> String {
        let title = chat.title.count > 40 ? String(chat.title.prefix(40)) + "…" : chat.title
        return "Delete \"\(title)\"?"
    }
    private func pinButton(_ chat: HermesSession) -> some View {
        Button { perform("Pin") { try await client.setPinned(chat, !chat.pinned) } } label: {
            Label(chat.pinned ? "Unpin" : "Pin", systemImage: chat.pinned ? "pin.slash" : "pin")
        }.tint(.orange).disabled(client.pendingSessionKeys.contains(chat.id)).accessibilityIdentifier("chats.swipe.pin")
    }
    private func renameButton(_ chat: HermesSession) -> some View {
        Button { renameText = chat.title; renaming = chat } label: { Label("Rename", systemImage: "pencil") }
            .disabled(client.pendingSessionKeys.contains(chat.id)).accessibilityIdentifier("chats.swipe.rename")
    }
    private func deleteButton(_ chat: HermesSession) -> some View {
        Button { pendingDelete = chat } label: { Label("Delete", systemImage: "trash") }
            .disabled(client.pendingSessionKeys.contains(chat.id)).accessibilityIdentifier("chats.swipe.delete")
    }
    private func perform(_ action: String, operation: @escaping @MainActor () async throws -> Void) {
        Task {
            do { try await operation() }
            catch { errorTitle = "Couldn't \(action) Chat"; actionError = error.localizedDescription }
        }
    }

    @ViewBuilder private var emptyState: some View {
        if !query.isEmpty { ContentUnavailableView.search(text: query) }
        else if client.state == .connecting {
            if showLoading { ProgressView() }
        } else if client.state == .connected {
            ContentUnavailableView("No Chats Yet", systemImage: "bubble.left.and.bubble.right",
                                   description: Text("Start one with the compose button."))
                .accessibilityIdentifier("chats.empty")
        } else {
            ContentUnavailableView {
                Label("Not Connected", systemImage: "network.slash")
            } description: {
                if case .failed(let message) = client.state { Text(message) }
                else { Text("Add your Hermes server in Settings.") }
            } actions: { Button("Open Settings") { showPhoneSettings = true } }
            .accessibilityIdentifier("chats.empty")
        }
    }
}

#Preview {
    ContentView()
}
