
import SwiftUI

struct ContentView: View {

    @State private var searchText = ""
    @State private var showSettings = false

    @State private var path: [Destination] = []

    private enum Destination: Hashable {
        case existing(HermesSession)
        case new(UUID, profile: String?)
    }

    private var client: HermesClient { HermesClient.shared }

    var body: some View {

        NavigationStack(path: $path) {

            List {
                if let notice = client.profileNotice {
                    Label(notice, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }

                ForEach(client.sessions.filter {
                    searchText.isEmpty ||
                    $0.title.localizedCaseInsensitiveContains(searchText)
                }) { chat in

                    NavigationLink(chat.title, value: Destination.existing(chat))
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
                        startNewChat(in: nil)
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .accessibilityLabel("New chat")
                    .accessibilityIdentifier("chats.new")
                }
            }
            .navigationDestination(for: Destination.self) { destination in
                switch destination {
                case .existing(let chat):
                    ChatInterfaceView(session: chat, onNewChat: startNewChat)
                case .new(let id, let profile):
                    ChatInterfaceView(profile: profile, onNewChat: startNewChat)
                        .id(id)
                }
            }
            .task {
                if client.isConfigured, client.state == .disconnected {
                    await client.connect()
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

    private func startNewChat(in profile: String?) {
        if let profile { client.browse(profile) }
        path = [.new(UUID(), profile: profile)]
    }
}

#Preview {
    ContentView()
}
