import AppIntents
import SwiftUI

struct AskHermesIntent: AppIntent, ProgressReportingIntent, CancellableIntent {
    static let title: LocalizedStringResource = "Ask Hermes"
    static let description = IntentDescription("Send a prompt to your configured Hermes server and get its reply. Open orbit if the reply takes longer or needs your input.")
    static let supportedModes: IntentModes = .background
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "Prompt", requestValueDialog: "What would you like to ask Hermes?")
    var prompt: String

    @Parameter(title: "Destination", default: .newChat)
    var destination: HermesChatDestination

    @Parameter(title: "Chat", requestDisambiguationDialog: "Which Hermes chat?")
    var chat: HermesChatEntity?

    static var parameterSummary: some ParameterSummary {
        When(\.$destination, .equalTo, .existingChat) {
            Summary("Ask Hermes \(\.$prompt) in \(\.$chat)") { \.$destination }
        } otherwise: {
            Summary("Ask Hermes \(\.$prompt) in a new chat") { \.$destination }
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<HermesAskResult> & ProvidesDialog & ShowsSnippetIntent {
        let task = Task {
            try await run {
                progress.totalUnitCount = -1
                progress.localizedDescription = String(localized: "Connecting to Hermes…")
            } waiting: {
                progress.localizedDescription = String(localized: "Waiting for Hermes…")
            }
        }
        let outcome = try await withTaskCancellationHandler {
            try await withIntentCancellationHandler {
                try await task.value
            } onCancel: { _ in task.cancel() }
        } onCancel: { task.cancel() }
        try Task.checkCancellation()
        guard UIApplication.shared.isProtectedDataAvailable else { throw CancellationError() }
        let presentation = outcome.presentation
        let snippet = HermesAskSnippetIntent()
        snippet.heading = presentation.heading
        snippet.bodyText = presentation.body
        snippet.isPreview = presentation.clipped
        snippet.action = presentation.action
        if let route = presentation.route { snippet.routeID = HermesHandoffRouter.shared.store(route) }
        return .result(value: HermesAskResult(outcome), dialog: presentation.dialog, snippetIntent: snippet)
    }

    @MainActor
    func run(connecting: () -> Void, waiting: @escaping () -> Void) async throws -> HermesAskOutcome {
        try Task.checkCancellation()
        guard UIApplication.shared.isProtectedDataAvailable else { throw CancellationError() }
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return HermesAskOutcome(.invalidPrompt, message: "Enter a question for Hermes.")
        }
        guard text.count <= 8_000 else {
            return HermesAskOutcome(.invalidPrompt, message: "Use 8,000 characters or fewer.")
        }
        guard HermesClient.shared.isConfigured else { return HermesAskOutcome(.notConfigured, route: .settings) }
        var selected: HermesChatEntity?
        if destination == .existingChat {
            if let chat {
                selected = chat
            } else {
                let entities: [HermesChatEntity]
                do { entities = try await HermesChatQuery.choices() }
                catch is CancellationError { throw CancellationError() }
                catch { return HermesShortcutTurn.connectionFailure(error) }
                guard !entities.isEmpty else { return HermesAskOutcome(.chatUnavailable, route: .chats) }
                selected = try await $chat.requestDisambiguation(among: entities, dialog: "Which Hermes chat?")
            }
        }
        try Task.checkCancellation()
        connecting()
        return try await HermesShortcutTurn(existing: selected).run(text, waiting: waiting)
    }
}

struct HermesShortcuts: AppShortcutsProvider {
    static let shortcutTileColor: ShortcutTileColor = .grayBlue

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskHermesIntent(),
            phrases: [
                "Ask Hermes with \(.applicationName)",
                "Ask Hermes in \(.applicationName)",
                "Ask Hermes with \(.applicationName) in \(\.$destination)"
            ],
            shortTitle: "Ask Hermes",
            systemImageName: "text.bubble",
            parameterPresentation: ParameterPresentation(for: \.$destination, summary: Summary("\(\.$destination)")) {
                OptionsCollection(HermesDestinationOptions(destination: .newChat),
                                  title: "New Chat", systemImageName: "square.and.pencil")
                OptionsCollection(HermesDestinationOptions(destination: .existingChat),
                                  title: "Existing Chat", systemImageName: "bubble.left.and.bubble.right")
            }
        )
    }
}

nonisolated private struct HermesDestinationOptions: DynamicOptionsProvider {
    let destination: HermesChatDestination

    func results() async throws -> [HermesChatDestination] { [destination] }
}
