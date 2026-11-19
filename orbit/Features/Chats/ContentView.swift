
import SwiftUI

struct ContentView: View {

    @State private var searchText = ""
    @State private var showSettings = false

    @State private var startNewChat = false

    /// Decided once at launch, not observed, so typing an address never closes onboarding mid-step.
    @AppStorage(AppearanceKey.accent) private var accent = Accent.mono
    @State private var onboardingAtLaunch = !HermesClient.shared.isConfigured
    @State private var showSetup = false

    private var client: HermesClient { HermesClient.shared }

    var body: some View {
        if onboardingAtLaunch {
            // The first frame on a fresh install, so it's shown in place rather than animated in as a cover.
            OnboardingView { startChat in
                startNewChat = startChat
                onboardingAtLaunch = false
            }
        } else {
            chats
        }
    }

    private var chats: some View {

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
            .overlay {
                if !client.isConfigured { noServer }
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
                    .accessibilityLabel("New chat")
                    .accessibilityIdentifier("chats.new")
                    .disabled(!client.isConfigured)
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
            .fullScreenCover(isPresented: $showSetup) {
                OnboardingView(startingAt: .connect) { startChat in
                    startNewChat = startChat
                    showSetup = false
                }
                .interactiveDismissDisabled()
            }
            .sheet(isPresented: $showSettings) {

                SettingsView()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
        }
    }

    private var noServer: some View {
        ContentUnavailableView {
            Label {
                Text("No server yet")
            } icon: {
                Image("Lockup")
                    .resizable()
                    .interpolation(.none)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 29 * 3)
                    .accessibilityHidden(true)
            }
        } description: {
            Text("Connect orbit to your Hermes dashboard to see your chats.")
        } actions: {
            Button {
                showSetup = true
            } label: {
                Text("Set up")
                    .font(.headline)
                    .foregroundStyle(accent.onColor)
                    .padding(.horizontal, 8)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .tint(accent.color)
            .accessibilityIdentifier("chats.empty.setup")
        }
    }
}

#Preview {
    ContentView()
}
