import SwiftUI

@main struct OrbitApp: App {

    @AppStorage(AppearanceKey.accent) private var accent = Accent.mono
    @AppStorage(AppearanceKey.theme) private var theme = Theme.system

    init() {
        Task.detached(priority: .utility) { MarkdownTranscript.pruneStaging() }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .tint(accent.color)
                .preferredColorScheme(theme.colorScheme)
        }
    }
}
