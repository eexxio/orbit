import AppIntents
import Observation
import SwiftUI

enum HermesHandoff: Equatable {
    case settings, chats
    case chat(scope: String, key: String, status: HermesAskStatus, admission: String?)

    var label: String {
        switch self {
        case .settings: String(localized: "Open settings in orbit")
        case .chats: String(localized: "Open orbit")
        case .chat: String(localized: "Open chat in orbit")
        }
    }
}

@Observable
final class HermesHandoffRouter {
    static let shared = HermesHandoffRouter()
    private var routes: [(id: String, route: HermesHandoff)] = []
    private(set) var pending: (id: String, route: HermesHandoff)?

    func store(_ route: HermesHandoff) -> String {
        let id = UUID().uuidString
        routes.append((id, route))
        if routes.count > 12 { routes.removeFirst() }
        return id
    }

    func open(_ id: String) {
        if let index = routes.firstIndex(where: { $0.id == id }) {
            pending = routes[index]
        } else {
            pending = (id, .chats)
        }
    }

    func takePending() -> HermesHandoff? {
        defer { pending = nil }
        return pending?.route
    }
}

struct HermesHandoffChat {
    let id = UUID()
    let scope: String
    let key: String
    let status: HermesAskStatus
    let admission: String?

    var needsCheck: Bool {
        [.timedOut, .deliveryUnknown, .queued, .needsInput].contains(status)
    }

    var dashboardURL: URL? {
        let client = HermesClient.shared
        guard scope == client.shortcutScope, let base = client.baseURL,
              var url = URLComponents(url: base.appendingPathComponent("chat"), resolvingAgainstBaseURL: false)
        else { return nil }
        url.user = nil
        url.password = nil
        url.fragment = nil
        url.queryItems = [.init(name: "resume", value: key), .init(name: "profile", value: client.profile)]
        return url.url
    }

    enum Check: Equatable {
        case checking, pending, unverified, finished, dashboard, noRequest
    }

    func check() async -> Check {
        let client = HermesClient.shared
        guard scope == client.shortcutScope else { return .unverified }
        let conversation = HermesConversation(storedKey: key)
        conversation.observeFrame = { $0["method"].text != nil }
        let deadline = Task {
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            conversation.close()
        }
        defer {
            deadline.cancel()
            conversation.close()
        }
        return await withTaskCancellationHandler {
            await check(conversation)
        } onCancel: {
            Task { @MainActor in conversation.close() }
        }
    }

    private func check(_ conversation: HermesConversation) async -> Check {
        let client = HermesClient.shared
        do {
            let snapshot = try await conversation.open()
            guard scope == client.shortcutScope, conversation.storedKey == key else { return .unverified }
            if status == .needsInput {
                if HermesShortcutTurn.hasInput(snapshot) { return .dashboard }
                return snapshot["open_requests"].list != nil || conversation.usesSessionAuthority
                    ? .noRequest : .dashboard
            }
            guard conversation.usesSessionAuthority, let admission else { return .unverified }
            let receipt = try await conversation.receipt(for: admission)
            guard scope == client.shortcutScope, receipt["admission_id"].text == admission else { return .unverified }
            switch receipt["status"].text {
            case "terminal": return .finished
            case "started", "queued": return .pending
            default: return .unverified
            }
        } catch {
            return status == .needsInput ? .dashboard : .unverified
        }
    }
}

struct OpenHermesHandoffIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Hermes Handoff"
    static let isDiscoverable = false
    static let supportedModes: IntentModes = .foreground
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "Route") var routeID: String

    init() {}

    init(routeID: String) { self.routeID = routeID }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard UIApplication.shared.isProtectedDataAvailable else { throw CancellationError() }
        HermesHandoffRouter.shared.open(routeID)
        return .result()
    }
}
