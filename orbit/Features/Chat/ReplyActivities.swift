import ActivityKit
import Foundation

/// Runs the one Live Activity a long reply gets, from the `LiveChat` that streams it.
///
/// Off unless turned on in Settings. It starts only after a reply has run for a while, follows
/// the earliest qualifying turn until that turn ends, and never claims "Stopped" until the
/// host answers the interrupt. Updates come from the app only, so once iOS suspends orbit the
/// card goes stale and says so instead of guessing.
@MainActor
final class ReplyActivities {
    static let shared = ReplyActivities()
    typealias State = ReplyActivityAttributes.ContentState

    private var activity: Activity<ReplyActivityAttributes>?
    private weak var chat: LiveChat?
    private var turn: UUID?
    private var route = ""
    /// Opaque route ids to session keys, so a tapped card (even a finished one) opens its chat.
    private var routes: [String: String] = [:]
    private var pending: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var refresher: Task<Void, Never>?
    private var shown: State?
    /// When the card last got fresh content; past its stale date it can't be trusted.
    private var updatedAt = Date.distantPast
    private var rateShownAt = Date.distantPast
    private var stopping = false

    private var isEnabled: Bool { UserDefaults.standard.bool(forKey: AppearanceKey.liveActivities) }

    /// How long a reply runs before it earns a Live Activity. UI tests shorten it.
    private var delay: Duration {
        let override = ProcessInfo.processInfo.environment["ORBIT_LIVE_ACTIVITY_DELAY"].flatMap(Double.init)
        return .seconds(override ?? 20)
    }

    func sessionKey(for route: String) -> String? { routes[route] }

    /// A cold launch can't know how a card left from before ended, so it removes it without an outcome.
    func endLeftovers() {
        for leftover in Activity<ReplyActivityAttributes>.activities {
            Task { await leftover.end(nil, dismissalPolicy: .immediate) }
        }
    }

    func turnStarted(_ chat: LiveChat) {
        let id = ObjectIdentifier(chat)
        pending[id]?.cancel()
        let turn = chat.latestPromptID
        let startedAt = Date.now
        pending[id] = Task { [weak self, weak chat] in
            do { try await Task.sleep(for: self?.delay ?? .seconds(20)) } catch { return }
            guard let self, let chat else { return }
            pending[id] = nil
            start(chat, turn: turn, startedAt: startedAt)
        }
    }

    private func start(_ chat: LiveChat, turn: UUID?, startedAt: Date) {
        guard isEnabled, activity == nil, ActivityAuthorizationInfo().areActivitiesEnabled,
              chat.isGenerating, chat.latestPromptID == turn, let key = chat.key else { return }
        let route = UUID().uuidString
        let state = state(for: chat)
        do {
            activity = try Activity.request(attributes: ReplyActivityAttributes(route: route, startedAt: startedAt),
                                            content: content(state), pushType: nil)
        } catch {
            return
        }
        self.chat = chat
        self.turn = turn
        self.route = route
        routes[route] = key
        shown = state
        stopping = false
        // Renews the stale date while the app is alive to see the turn; a suspended app lets it lapse.
        refresher = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
                guard let self, let activity = self.activity, let shown = self.shown else { return }
                await activity.update(self.content(shown))
            }
        }
    }

    /// Something the card shows may have changed.
    func changed(_ chat: LiveChat) {
        guard let activity, self.chat === chat, chat.latestPromptID == turn, !stopping else { return }
        var state = state(for: chat)
        // A new rate alone shows at most every 5 s.
        if var rateless = shown, state.tokensPerSecond != rateless.tokensPerSecond {
            rateless.tokensPerSecond = state.tokensPerSecond
            if rateless == state, Date.now.timeIntervalSince(rateShownAt) < 5 { state.tokensPerSecond = shown?.tokensPerSecond }
        }
        guard state != shown else { return }
        if state.tokensPerSecond != shown?.tokensPerSecond { rateShownAt = .now }
        shown = state
        Task { await activity.update(content(state)) }
    }

    /// A Stop from the card or the composer: "Stopping…" until the host answers.
    func stopRequested(_ chat: LiveChat, interrupt: Task<Bool, Never>?) {
        guard let activity, self.chat === chat, !stopping else { return }
        stopping = true
        let state = State(phase: .stopping)
        shown = state
        Task {
            await activity.update(content(state))
            let confirmed = await interrupt?.value ?? true
            finish(confirmed ? .stopped : .unconfirmed)
        }
    }

    func turnEnded(_ chat: LiveChat) {
        pending.removeValue(forKey: ObjectIdentifier(chat))?.cancel()
        guard self.chat === chat, !stopping else { return }
        switch chat.replyState {
        case .completed: finish(.done)
        case .stopped: finish(.stopped)
        case .failed: finish(.failed)
        case .interrupted: finish(.interrupted)
        default: endAll()
        }
    }

    /// The card's Stop: only for the turn it shows, and only while that turn's socket can take it.
    func stop(route: String) {
        guard route == self.route, let chat, chat.latestPromptID == turn, chat.canInterrupt, !stopping else { return }
        chat.stop()
    }

    /// Opt-out, sign-out or a server change: the card goes away without an outcome.
    func endAll() {
        pending.values.forEach { $0.cancel() }
        pending.removeAll()
        let current = activity
        reset()
        for leftover in Activity<ReplyActivityAttributes>.activities where leftover.id != current?.id {
            Task { await leftover.end(nil, dismissalPolicy: .immediate) }
        }
        if let current { Task { await current.end(nil, dismissalPolicy: .immediate) } }
    }

    private func finish(_ phase: State.Phase) {
        guard let activity else { return }
        reset()
        Task { await activity.end(ActivityContent(state: State(phase: phase), staleDate: nil), dismissalPolicy: .after(.now + 30)) }
    }

    private func reset() {
        refresher?.cancel()
        refresher = nil
        activity = nil
        chat = nil
        turn = nil
        shown = nil
        stopping = false
    }

    private func content(_ state: State) -> ActivityContent<State> {
        updatedAt = .now
        return ActivityContent(state: state, staleDate: .now + Self.staleAfter)
    }

    private static let staleAfter: TimeInterval = 45

    /// Back in the foreground after iOS suspended orbit: a card that went stale ends,
    /// since the app missed whatever happened and the chat shows the truth.
    func appBecameActive() {
        guard activity != nil, Date.now.timeIntervalSince(updatedAt) >= Self.staleAfter else { return }
        endAll()
    }

    private func state(for chat: LiveChat) -> State {
        var state = State(phase: .thinking, canStop: chat.canInterrupt)
        let tools = chat.messages.filter { chat.liveToolIDs.contains($0.id) }.compactMap(\.tool?.name)
        if !tools.isEmpty {
            state.phase = .tool
            let showTools = UserDefaults.standard.object(forKey: AppearanceKey.showToolCalls) as? Bool ?? true
            if showTools {
                state.toolCount = tools.count
                state.toolKind = tools.count == 1 ? Self.kind(of: tools[0]) : .other
            } else {
                state.toolKind = .hidden
            }
        } else if let id = chat.streamingID, let message = chat.messages.first(where: { $0.id == id }) {
            state.phase = .replying
            state.tokensPerSecond = message.rate.map { Int($0.perSecond.rounded()) }
        }
        return state
    }

    private static func kind(of tool: String) -> State.ToolKind {
        switch tool {
        case "web_search", "web_extract": .web
        case "read_file", "search_files": .files
        default: .other
        }
    }
}
