#if DEBUG
import Foundation

/// Launch-argument hooks for the screenshot job (`.github/workflows/screenshots.yml`),
/// which drives the app with `simctl` and therefore cannot tap a row.
/// Debug builds only, so a release build ignores them entirely.
enum ScreenshotLaunch {

    /// `-orbit.chat <session key>`: open that chat once the app has connected.
    static var chat: String? {
        let key = (UserDefaults.standard.string(forKey: "orbit.chat") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : key
    }
}
#endif
