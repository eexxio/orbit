import AppIntents
import Foundation

/// The Live Activity's Stop button. It runs in the app, which owns the socket that runs the turn.
struct StopReplyIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Stop Reply"
    static let isDiscoverable = false

    @Parameter(title: "Reply")
    var route: String

    init() {}
    init(route: String) { self.route = route }

    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        await ReplyActivities.shared.stop(route: route)
        #endif
        return .result()
    }
}
