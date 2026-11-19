import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var searchText = ""
    @State private var showSettings = false
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

    private var filtered: [HermesSession] {
        client.sessions.filter { searchText.isEmpty || $0.title.localizedCaseInsensitiveContains(searchText) }
            .sorted {
                let a = $0.lastActive ?? 0, b = $1.lastActive ?? 0
                if a != b { return a > b }
                let comparison = $0.title.localizedStandardCompare($1.title)
                return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
            }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TimelineView(.periodic(from: activeDate, by: 60)) { context in
                    let pinned = filtered.filter(\.pinned)
                    let recent = filtered.filter { !$0.pinned }
                    List {
                        if !pinned.isEmpty { Section("Pinned") { rows(pinned, now: context.date) } }
                        if !recent.isEmpty {
                            if pinned.isEmpty { rows(recent, now: context.date) }
                            else { Section("Recent") { rows(recent, now: context.date) } }
                        }
                    }
                    .coordinateSpace(name: "chatList")
                    .animation(.default, value: filtered)
                    .scrollContentBackground(.hidden)
                    .background(Color(uiColor: .systemGroupedBackground))
                    .overlay { if filtered.isEmpty { emptyState } }
                    .refreshable { await client.refreshSessions() }
                }
            }
            .navigationTitle("Chats").navigationBarTitleDisplayMode(.large)
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }.accessibilityLabel("Settings")
                }
                ToolbarSpacer(.flexible, placement: .bottomBar)
                ToolbarItem(placement: .bottomBar) {
                    Button {
                        newChatID = UUID()
                        startNewChat = true
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .accessibilityLabel("New chat")
                    .accessibilityIdentifier("chats.new")
                }
            }
            .navigationDestination(isPresented: $startNewChat) {
                ChatInterfaceView()
                    .id(newChatID)
                    .navigationBarTitleDisplayMode(.inline)
            }
            .task { if client.isConfigured, client.state == .disconnected { await client.connect() } }
            .task(id: client.state) {
                showLoading = false
                if client.state == .connecting {
                    try? await Task.sleep(for: .seconds(1))
                    if !Task.isCancelled { showLoading = true }
                }
            }
            .onAppear { if client.state == .connected { Task { await client.refreshSessions() } } }
            .onChange(of: scenePhase) { _, phase in if phase == .active { activeDate = .now } }
            .sheet(isPresented: $showSettings) {
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
        }
    }

    private var trimmedName: String { renameText.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var host: String { client.baseURL?.host() ?? "the server" }

    private func rows(_ chats: [HermesSession], now: Date) -> some View {
        ForEach(chats) { chat in
            NavigationLink {
                ChatInterfaceView(sessionKey: chat.id).navigationBarTitleDisplayMode(.inline)
            } label: {
                ChatRow(chat: chat, isReplying: client.replyingKeys.contains(chat.id), now: now)
            }
            .swipeActions(edge: .leading, allowsFullSwipe: true) { pinButton(chat) }
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                deleteButton(chat).tint(.red)
                renameButton(chat).tint(.gray)
            }
            .contextMenu { pinButton(chat); renameButton(chat); deleteButton(chat) }
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
        if !searchText.isEmpty { ContentUnavailableView.search(text: searchText) }
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
            } actions: { Button("Open Settings") { showSettings = true } }
            .accessibilityIdentifier("chats.empty")
        }
    }
}
