import SwiftUI

@main struct OrbitApp: App {

    @AppStorage(AppearanceKey.accent) private var accent = Accent.mono
    @AppStorage(AppearanceKey.theme) private var theme = Theme.system

    var body: some Scene {
        WindowGroup {
            ContentView()
                .tint(accent.color)
                .preferredColorScheme(theme.colorScheme)
        }
    }
}
