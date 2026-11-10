
import SwiftUI

struct ContentView: View {

    @State private var searchText = ""
    @State private var showSettings = false

    // Sample chat data
    private let chats = [
        "hello",
        "SwiftUI Development",
        "Learning Python",
        "Project Planning",
        "Travel Ideas",
        "App Design",
        "Artificial Intelligence",
        "Business Ideas",
        "Workout Routine",
        "Recipe Suggestions",
        "iOS Development",
        "Study Notes",
        "Technology News",
        "Creative Writing",
        "Personal Assistant"
    ]

    var body: some View {

        NavigationStack {

            List {

                ForEach(chats.filter {
                    searchText.isEmpty ||
                    $0.localizedCaseInsensitiveContains(searchText)
                }, id: \.self) { chat in

                    NavigationLink(chat) {

                        ChatInterfaceView()
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
                        // Write action
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                }
            }
            .sheet(isPresented: $showSettings) {

                NavigationStack {

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
    ContentView()
}
