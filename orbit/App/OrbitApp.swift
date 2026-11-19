import SwiftUI

@main struct OrbitApp: App {

    @AppStorage(AppearanceKey.accent) private var accent = Accent.mono
    @AppStorage(AppearanceKey.theme) private var theme = Theme.system

    var body: some Scene {
        WindowGroup(id: "chats", for: ChatWindow.self) { $window in
            ContentView(window: window)
                .tint(accent.color)
                .preferredColorScheme(theme.colorScheme)
        }
        .commands { ChatCommands() }
    }
}

struct ChatWindow: Codable, Hashable {
    var id = UUID()
    var sessionID: String?
    var account: String?
    var profile: String?
}
