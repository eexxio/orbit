
import SwiftUI
import Playgrounds

struct ChatUI: View {
    @State private var searchText = ""
    @State private var showSettings = false

    var body: some View {
        NavigationView {
            List {
                NavigationLink("hello") {
                    Text("s")
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
                // Top-right Settings button
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }

                // Push the Write button to the bottom-right
                ToolbarSpacer(.flexible, placement: .bottomBar)

                // Native bottom toolbar button
                ToolbarItem(placement: .bottomBar) {
                    Button {
                        // Write action
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                }
            }

            .sheet(isPresented: $showSettings) {
                NavigationView {
                    List {
                        Text("Account")
                        Text("Notifications")
                        Text("Appearance")
                        Text("Privacy")
                    }
                    .navigationTitle("Settings")
                    .navigationBarTitleDisplayMode(.inline)
                }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
        }
    }
}

#Preview {
    ChatUI()
}

#Playground {
    _ = 1 + 2
}
