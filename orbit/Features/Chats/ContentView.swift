
import SwiftUI

struct ContentView: View {

    @State private var searchText = ""
    @State private var showSettings = false

    @State private var startNewChat = false

    private var client: HermesClient { HermesClient.shared }

    var body: some View {

        NavigationStack {

            List {

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
                        startNewChat = true
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                }
            }
            .navigationDestination(isPresented: $startNewChat) {
                ChatInterfaceView()
                    .navigationBarTitleDisplayMode(.inline)
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
}

#Preview {
    ContentView()
}
