import ActivityKit
import Foundation

/// What a reply's Live Activity shows. Shared by the app and the widget extension.
///
/// Only fixed states and counts cross into ActivityKit: no prompt, chat title, tool name,
/// server or profile. `route` is an opaque local id the app maps back to the chat.
nonisolated struct ReplyActivityAttributes: ActivityAttributes {
    nonisolated struct ContentState: Codable, Hashable, Sendable {
        enum Phase: String, Codable, Hashable, Sendable {
            case thinking, tool, replying, stopping, stopped, done, failed, interrupted, unconfirmed, unavailable

            var isTerminal: Bool { ![.thinking, .tool, .replying, .stopping].contains(self) }
        }

        /// The tool kind, reduced to what is safe to show off the app.
        enum ToolKind: String, Codable, Hashable, Sendable { case web, files, other, hidden }

        var phase: Phase
        var toolCount = 0
        var toolKind: ToolKind?
        var tokensPerSecond: Int?
        /// True only while the live socket that runs this turn can interrupt it.
        var canStop = false
    }

    var route: String
    /// When the prompt was sent, for the system's count-up timer.
    var startedAt: Date
}

extension ReplyActivityAttributes.ContentState {
    var status: String {
        switch phase {
        case .thinking: String(localized: "Thinking…")
        case .tool:
            switch toolKind {
            case .hidden: String(localized: "Working…")
            default: toolCount > 1 ? String(localized: "Running \(toolCount) tools") : String(localized: "Running a tool")
            }
        case .replying: String(localized: "Replying…")
        case .stopping: String(localized: "Stopping…")
        case .stopped: String(localized: "Stopped")
        case .done: String(localized: "Reply ready")
        case .failed: String(localized: "Reply failed")
        case .interrupted: String(localized: "Reply interrupted")
        case .unconfirmed: String(localized: "Couldn’t confirm stop")
        case .unavailable: String(localized: "Status unavailable")
        }
    }

    /// A safe line under the status: the tool category or the reply's rate.
    var detail: String? {
        switch phase {
        case .tool where toolCount == 1:
            switch toolKind {
            case .web: String(localized: "Searching the web")
            case .files: String(localized: "Working with files")
            default: nil
            }
        case .replying: tokensPerSecond.map { String(localized: "~\($0) tok/s") }
        default: nil
        }
    }

    var accessibleDetail: String? {
        if phase == .replying, let tokensPerSecond { return String(localized: "About \(tokensPerSecond) tokens per second") }
        return detail
    }

    var symbol: String {
        switch phase {
        case .thinking: "brain"
        case .tool: toolKind == .hidden ? "circle.dotted" : "wrench.and.screwdriver"
        case .replying: "ellipsis.bubble"
        case .stopping, .stopped: "stop.circle"
        case .done: "checkmark.circle"
        case .failed, .interrupted, .unconfirmed: "exclamationmark.circle"
        case .unavailable: "clock.badge.exclamationmark"
        }
    }

    var showsTimer: Bool { !phase.isTerminal && phase != .stopping }
}

extension ReplyActivityAttributes {
    /// Opens the chat this activity belongs to.
    var url: URL { URL(string: "orbit://chat/\(route)")! }
}
