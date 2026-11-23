import SwiftUI

@main struct OrbitApp: App {

    @AppStorage(AppearanceKey.accent) private var accent = Accent.mono
    @AppStorage(AppearanceKey.theme) private var theme = Theme.system
    @Environment(\.scenePhase) private var scenePhase

    init() { ReplyActivities.shared.endLeftovers() }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .tint(accent.color)
                .preferredColorScheme(theme.colorScheme)
                .onChange(of: scenePhase) {
                    if scenePhase == .active { ReplyActivities.shared.appBecameActive() }
                }
        }
    }
}
