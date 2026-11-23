
import SwiftUI

struct ContentView: View {

    @State private var searchText = ""
    @State private var showSettings = false

    @State private var startNewChat = false
    @State private var newChatID = UUID()
    @State private var showHandoff = false
    @State private var handoffChat: HermesHandoffChat?
    @State private var handoffNotice: LocalizedStringResource?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.appearsActive) private var appearsActive

    private var canOpenHandoff: Bool { scenePhase == .active && appearsActive }

    private var client: HermesClient { HermesClient.shared }

    var body: some View {

        NavigationStack {

            List {

                if let handoffNotice {
                    Text(handoffNotice).foregroundStyle(.secondary)
                }

                ForEach(client.sessions.filter {
                    searchText.isEmpty ||
                    $0.title.localizedCaseInsensitiveContains(searchText)
                }) { chat in

                    NavigationLink(chat.title) {

                        ChatInterfaceView(sessionKey: chat.id)
                            .navigationBarTitleDisplayMode(.inline)
                    }
                }
            }
            .navigationTitle("Chats")
            .navigationBarTitleDisplayMode(.large)
            .searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: .automatic),
                prompt: "Search"
            )
            .toolbar {

                ToolbarItem(placement: .topBarTrailing) {

                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
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
            .navigationDestination(isPresented: $showHandoff) {
                if let handoffChat {
                    ChatInterfaceView(sessionKey: handoffChat.key, handoff: handoffChat)
                        .id(handoffChat.id)
                        .navigationBarTitleDisplayMode(.inline)
                }
            }
            .onChange(of: canOpenHandoff ? HermesHandoffRouter.shared.pending?.id : nil, initial: true) {
                guard canOpenHandoff, let route = HermesHandoffRouter.shared.takePending() else { return }
                Task { await openHandoff(route) }
            }
            .task {
                if client.isConfigured, client.state == .disconnected {
                    await client.refreshSessions()
                }
            }
            .onAppear {
                if client.state == .connected {
                    Task { await client.refreshSessions() }
                }
            }
            .sheet(isPresented: $showSettings) {

                SettingsView()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
        }
    }

    private func openHandoff(_ route: HermesHandoff) async {
        showSettings = false
        showHandoff = false
        startNewChat = false
        handoffNotice = nil
        switch route {
        case .settings:
            showSettings = true
        case .chats:
            break
        case let .chat(scope, key, status, admission):
            guard scope.hasPrefix(client.shortcutAccount + ":") else {
                handoffNotice = "This chat belongs to a different Hermes connection."
                return
            }
            do {
                try await client.ensureShortcutSignIn(refreshProfile: true)
                guard scope == client.shortcutScope else {
                    handoffNotice = "This chat belongs to a different Hermes connection."
                    return
                }
                guard try await client.validateShortcutChat(key) else {
                    handoffNotice = "This chat isn’t available."
                    return
                }
                guard scope == client.shortcutScope else {
                    handoffNotice = "This chat belongs to a different Hermes connection."
                    return
                }
                handoffChat = HermesHandoffChat(scope: scope, key: key, status: status, admission: admission)
                showHandoff = true
            } catch {
                handoffNotice = "I couldn’t verify the reply. Check the transcript before asking again."
            }
        }
    }
}

#Preview {
    ContentView()
}
