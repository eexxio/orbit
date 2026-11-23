import AppIntents
import SwiftUI

enum HermesAskStatus: String, AppEnum {
    case completed, invalidPrompt, notConfigured, signInRequired, offline, unreachable
    case chatUnavailable, busy, queued, timedOut, deliveryUnknown, needsInput, replyTooLarge, noText, failed

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Hermes Status"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .completed: "Completed", .invalidPrompt: "Check your prompt", .notConfigured: "Set up Hermes",
        .signInRequired: "Sign in to Hermes", .offline: "You’re offline", .unreachable: "Can’t reach Hermes",
        .chatUnavailable: "Chat unavailable", .busy: "Chat not ready", .queued: "Question queued",
        .timedOut: "Reply taking longer", .deliveryUnknown: "Check the chat", .needsInput: "Hermes needs your input",
        .replyTooLarge: "Reply too large", .noText: "No text reply", .failed: "Hermes couldn’t finish"
    ]

    var message: LocalizedStringResource {
        switch self {
        case .completed: "Hermes replied."
        case .invalidPrompt: "Enter a question for Hermes."
        case .notConfigured: "Add your Hermes server in orbit Settings."
        case .signInRequired: "Open orbit to sign in to Hermes."
        case .offline: "You’re offline. Your question wasn’t sent."
        case .unreachable: "I couldn’t reach Hermes. Your question wasn’t sent."
        case .chatUnavailable: "That chat isn’t available. Choose another in orbit."
        case .busy: "Open the chat in orbit to send your question."
        case .queued: "Hermes queued your question. Open orbit to check the chat."
        case .timedOut: "Hermes hasn’t finished replying here. Open orbit to check the chat."
        case .deliveryUnknown: "I couldn’t confirm the reply. Check the chat in orbit before asking again."
        case .needsInput: "Hermes needs your input. Open orbit to review the request."
        case .replyTooLarge: "Hermes replied, but the reply is too large to return here. Open orbit to read it."
        case .noText: "Hermes finished without a text reply. Check the chat in orbit."
        case .failed: "Hermes couldn’t finish the reply. Check the chat in orbit."
        }
    }
}

struct HermesAskOutcome {
    let status: HermesAskStatus
    let message: LocalizedStringResource
    let route: HermesHandoff?
    var reply = ""

    init(_ status: HermesAskStatus, message: LocalizedStringResource? = nil, route: HermesHandoff? = nil) {
        self.status = status
        self.message = message ?? status.message
        self.route = route
    }

    var presentation: (heading: String, body: String, clipped: Bool, dialog: IntentDialog, route: HermesHandoff?, action: String) {
        if status != .completed {
            return (String(localized: HermesAskStatus.caseDisplayRepresentations[status]?.title ?? "Ask Hermes"),
                    String(localized: message), false, IntentDialog(message), route, route?.label ?? "")
        }
        let prose = Self.plainText(reply)
        let lines = prose.split(separator: "\n", omittingEmptySubsequences: false)
        let clipped = prose.count > 480 || lines.count > 6
        let excerpt = clipped ? String(lines.prefix(6).joined(separator: "\n").prefix(479))
            .trimmingCharacters(in: .whitespacesAndNewlines) + "…" : prose
        let spoken = prose.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let withoutLinks = reply.replacingOccurrences(of: #"(?<!!)\[([^\]]+)\]\([^)]+\)"#,
                                                       with: "$1", options: .regularExpression)
        let unsuitable = withoutLinks.range(of: #"\x60|!\[|\||(?:https?://|www\.)\S+"#, options: .regularExpression) != nil
        let long = spoken.count > 240 || spoken.isEmpty || unsuitable
        let punctuation = spoken.last.map { ".!?…".contains($0) } == true ? "" : "."
        let dialog = long ? IntentDialog("Hermes replied. Open orbit to read it.")
            : IntentDialog(full: "Hermes says: \(spoken)\(punctuation)", supporting: "Hermes replied.")
        let actionRoute = route == .chats && !long ? nil : route
        return ("", excerpt, clipped, dialog, actionRoute, actionRoute?.label ?? "")
    }

    private static func plainText(_ markdown: String) -> String {
        markdown
            .replacingOccurrences(of: #"(?sm)^[ \t]*(?:[\x60]{3,}|~{3,}).*?^[ \t]*(?:[\x60]{3,}|~{3,})[^\n]*"#,
                                  with: String(localized: "[Code block]"), options: .regularExpression)
            .replacingOccurrences(of: #"!?\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"(?m)^[ \t]{0,3}(?:#{1,6}|>)\s+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(\*\*|__|~~|\x60)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(\*|_)(?=\S)(.+?)(?<=\S)\1"#, with: "$2", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct HermesAskResult: TransientAppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Hermes Result"
    let id = UUID()

    @Property(title: "Status") var status: HermesAskStatus
    @Property(title: "Reply") var reply: String
    @Property(title: "Message") var message: String

    var displayRepresentation: DisplayRepresentation {
        HermesAskStatus.caseDisplayRepresentations[status] ?? "Hermes Result"
    }

    init() {
        status = .failed
        reply = ""
        message = ""
    }

    init(_ outcome: HermesAskOutcome) {
        status = outcome.status
        reply = outcome.reply
        message = String(localized: outcome.message)
    }
}

struct HermesAskSnippetIntent: SnippetIntent {
    static let title: LocalizedStringResource = "Hermes Result"
    static let isDiscoverable = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "Heading") var heading: String
    @Parameter(title: "Body") var bodyText: String
    @Parameter(title: "Is Preview", default: false) var isPreview: Bool
    @Parameter(title: "Action") var action: String
    @Parameter(title: "Route") var routeID: String?

    @MainActor
    func perform() async throws -> some IntentResult & ShowsSnippetView {
        guard UIApplication.shared.isProtectedDataAvailable else { throw CancellationError() }
        return .result(view: HermesAskCard(heading: heading, bodyText: bodyText, isPreview: isPreview,
                                           action: action, routeID: routeID))
    }
}

private struct HermesAskCard: View {
    let heading: String
    let bodyText: String
    let isPreview: Bool
    let action: String
    let routeID: String?

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !heading.isEmpty {
                Text(verbatim: heading)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
            }
            if isPreview || (typeSize.isAccessibilitySize && bodyText.count > 200) {
                Text("Preview").font(.caption).foregroundStyle(.secondary)
            }
            Text(verbatim: typeSize.isAccessibilitySize && bodyText.count > 200
                 ? String(bodyText.prefix(199)) + "…" : bodyText)
                .lineLimit(typeSize.isAccessibilitySize ? 4 : 6)
            if let routeID, !action.isEmpty {
                Button(intent: OpenHermesHandoffIntent(routeID: routeID)) {
                    Text(verbatim: action).frame(minHeight: 44)
                }
                .accessibilityHint("Opens orbit")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
    }
}
