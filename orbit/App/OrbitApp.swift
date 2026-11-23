import SwiftUI

@main struct OrbitApp: App {

    @AppStorage(AppearanceKey.accent) private var accent = Accent.mono
    @AppStorage(AppearanceKey.theme) private var theme = Theme.system

    var body: some Scene {
        WindowGroup {
            content
                .tint(accent.color)
                .preferredColorScheme(theme.colorScheme)
        }
    }

    @ViewBuilder
    private var content: some View {
        #if DEBUG && targetEnvironment(simulator)
        if let probe = AskHermesUITestProbe() {
            probe
        } else {
            ContentView()
        }
        #else
        ContentView()
        #endif
    }
}
