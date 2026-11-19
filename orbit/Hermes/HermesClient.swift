import Foundation
import Observation

// The Hermes Agent dashboard endpoints this client talks to:
//   • GET  /api/status                 – public; tells us how to sign in
//   • POST /auth/password-login        – username/password, sets a session cookie
//   • GET  /                           – an open dashboard's page carries its session token
//   • GET  /api/profiles/active        – `{current}` profile name
//   • GET  /api/sessions               – session list
//   • GET  /api/sessions/{key}/mutation-snapshot – mutation revision/generation
//   • PATCH /api/sessions/{key}         – title or pinned, profile and mutation identity
//   • DELETE /api/sessions/{key}        – profile and mutation identity in query
//   • GET  /api/sessions/{key}/messages – transcript
//   • GET  /api/profiles/{name}/soul   – `{content, exists}`: the profile's SOUL.md
//   • PUT  /api/profiles/{name}/soul   – `{content}` replaces SOUL.md
//   • POST /api/auth/ws-ticket         – single-use ticket for the gateway socket
//   • WS   /api/ws                     – JSON-RPC 2.0 gateway: session.create / session.resume /
//                                        prompt.submit / session.interrupt, streaming `message.delta` / `message.interim` /
//                                        `message.complete`, `reasoning.delta` / `reasoning.available`,
//                                        and `tool.start` / `tool.complete` events.

// MARK: - Client

@MainActor @Observable
final class HermesClient {
    static let shared = HermesClient()

    enum State: Equatable { case disconnected, connecting, connected, failed(String) }

    // Saved configuration
    var address: String { didSet { UserDefaults.standard.set(address, forKey: "hermes.address") } }
    var username: String { didSet { UserDefaults.standard.set(username, forKey: "hermes.username") } }
    var password: String { didSet { Keychain.write(password, "password") } }
    /// Optional Cloudflare Access service token, for dashboards behind Cloudflare Tunnel.
    var accessClientID: String { didSet { UserDefaults.standard.set(accessClientID, forKey: "hermes.cfid") } }
    var accessClientSecret: String { didSet { Keychain.write(accessClientSecret, "cfsecret") } }

    private(set) var state: State = .disconnected
    private(set) var serverVersion: String?
    private(set) var profile = "default"
    private(set) var sessions: [HermesSession] = []
    private(set) var didLoadSessions = false
    @ObservationIgnored private var attemptedInitialConnection = false
    private(set) var replyingKeys: Set<String> = []
    private(set) var pendingSessionKeys: Set<String> = []
    private(set) var pendingDeletes: Set<String> = []
    private(set) var deletedSessionKeys: Set<String> = []
    @ObservationIgnored private var localActivity: [String: Double] = [:]

    private(set) var cache: ConversationCache
    @ObservationIgnored private var prefetchTask: Task<Void, Never>?
    @ObservationIgnored private var session = URLSession(configuration: .ephemeral)
    @ObservationIgnored private var pageToken: String?
    @ObservationIgnored private var signedIn = false
    @ObservationIgnored private var signInTask: Task<Void, Error>?
    /// Chats with a turn running or a screen showing them, by session key, so leaving a chat
    /// mid-reply doesn't drop it. Not observed: views watch the `LiveChat` itself.
    @ObservationIgnored private var liveChats: [String: LiveChat] = [:]
    @ObservationIgnored private var retainedRoutes: [String: ChatReference] = [:]
    @ObservationIgnored private var unsavedChats: [ChatReference] = []
    @ObservationIgnored private var scopeRevision = UUID()

    private final class ChatReference {
        weak var chat: LiveChat?
        init(_ chat: LiveChat) { self.chat = chat }
    }

    private init() {
        let d = UserDefaults.standard
        let savedAddress = d.string(forKey: "hermes.address") ?? ""
        let savedUsername = d.string(forKey: "hermes.username") ?? ""
        address = savedAddress
        username = savedUsername
        accessClientID = d.string(forKey: "hermes.cfid") ?? ""
        password = Keychain.read("password") ?? ""
        accessClientSecret = Keychain.read("cfsecret") ?? ""
        cache = ConversationCache(address: savedAddress, username: savedUsername)
        // The cached list shows at once; the server's replaces it once signed in.
        sessions = cache.sessions
    }

    var isConfigured: Bool { baseURL != nil }

    var baseURL: URL? {
        var raw = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        if !raw.contains("://") { raw = "https://" + raw }
        while raw.hasSuffix("/") { raw.removeLast() }
        guard let url = URL(string: raw), let scheme = url.scheme, ["http", "https"].contains(scheme), url.host != nil
        else { return nil }
        return url
    }

    // MARK: Connection lifecycle

    func connectWorkspaceIfNeeded() async {
        guard !attemptedInitialConnection, isConfigured, state == .disconnected else { return }
        attemptedInitialConnection = true
        await Task { await connect() }.value
    }

    /// Drops any sign-in and connects again with the current settings.
    func connect() async {
        state = .connecting
        let scopeChanged = cache.accountScope != ConversationCache.scope(address: address, username: username)
        if scopeChanged {
            deletedSessionKeys = []
            didLoadSessions = false
            shutDownLiveChats()
        }
        signOutLocally()
        cache = ConversationCache(address: address, username: username)
        sessions = cache.sessions
        do {
            try await ensureSignedIn()
            await refreshSessions()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func disconnect() {
        deletedSessionKeys = []
        didLoadSessions = false
        shutDownLiveChats()
        signOutLocally()
        cache.clear()
        sessions = []
        state = .disconnected
    }

    private func signOutLocally() {
        prefetchTask?.cancel()
        prefetchTask = nil
        signInTask?.cancel()
        signInTask = nil
        signedIn = false
        pageToken = nil
        session.invalidateAndCancel()
        session = URLSession(configuration: .ephemeral)
    }

    func ensureSignedIn() async throws {
        if signedIn { return }
        if let task = signInTask { return try await task.value }
        let task = Task { try await self.performSignIn() }
        signInTask = task
        defer { signInTask = nil }
        try await task.value
    }

    private func performSignIn() async throws {
        guard let base = baseURL else { throw HermesError.notConfigured }
        state = .connecting
        do {
            let (statusData, statusResponse) = try await raw(request(base, "api/status"))
            guard statusResponse.statusCode == 200, let status = JSON.decode(statusData),
                  status["auth_required"].flag != nil else { throw HermesError.notDashboard }
            serverVersion = status["version"].text

            if status["auth_required"].flag == false {
                // An open dashboard: its page carries the token every /api route checks.
                let (page, _) = try await raw(request(base, ""))
                guard let token = Self.pageToken(in: page) else { throw HermesError.notDashboard }
                pageToken = token
            } else {
                guard status["auth_providers"].list?.contains(.string("basic")) != false else { throw HermesError.browserOnly }
                let body: JSON = .object(["provider": .string("basic"), "username": .string(username),
                                          "password": .string(password)])
                let (data, response) = try await raw(request(base, "auth/password-login", method: "POST", body: body))
                switch response.statusCode {
                case 200..<300: break
                case 401, 403: throw HermesError.wrongPassword
                default: throw HermesError.http(response.statusCode, Self.detail(data))
                }
            }
            signedIn = true
            let active = try? await getJSON("api/profiles/active")
            if let current = active?["current"].text, !current.isEmpty, profile != current {
                shutDownLiveChats()
                deletedSessionKeys = []
                didLoadSessions = false
                profile = current
            }
            state = .connected
        } catch {
            signedIn = false
            state = .failed(error.localizedDescription)
            throw error
        }
    }

    // MARK: Live chats

    func setReplying(_ key: String, _ replying: Bool) {
        if replying { replyingKeys.insert(key) } else { replyingKeys.remove(key) }
    }

    func bumpSession(_ key: String) {
        let now = Date().timeIntervalSince1970
        localActivity[key] = now
        if let index = sessions.firstIndex(where: { $0.id == key }) {
            sessions[index].lastActive = now
            cache.store(sessions: sessions)
        }
    }

    func renameSession(_ chat: HermesSession, title: String) async throws {
        try await mutateSession(chat, fields: ["title": .string(title)])
    }

    func setPinned(_ chat: HermesSession, _ pinned: Bool) async throws {
        try await mutateSession(chat, fields: ["pinned": .bool(pinned)])
    }

    func deleteSession(_ chat: HermesSession) async throws {
        try await mutateSession(chat, fields: nil)
    }

    private func mutateSession(_ chat: HermesSession, fields: [String: JSON]?) async throws {
        guard !pendingSessionKeys.contains(chat.id) else { return }
        let revision = scopeRevision
        let original = sessions.first { $0.id == chat.id } ?? chat
        pendingSessionKeys.insert(chat.id)
        if let fields, let index = sessions.firstIndex(where: { $0.id == chat.id }) {
            if let title = fields["title"]?.text { sessions[index].title = title }
            if let pinned = fields["pinned"]?.flag { sessions[index].pinned = pinned }
        } else if fields == nil {
            pendingDeletes.insert(chat.id)
            sessions.removeAll { $0.id == chat.id }
        }
        cache.store(sessions: sessions)
        defer {
            if revision == scopeRevision {
                pendingSessionKeys.remove(chat.id)
                pendingDeletes.remove(chat.id)
            }
        }
        do {
            try await ensureSignedIn()
            guard revision == scopeRevision else { return }
            guard let base = baseURL else { throw HermesError.notConfigured }
            let path = "api/sessions/\(chat.id)"
            var snapshotRequest = request(base, path + "/mutation-snapshot", query: ["profile": profile])
            let (snapshotData, snapshotResponse) = try await authorizedRaw(&snapshotRequest)
            guard revision == scopeRevision else { return }
            var identity: [String: JSON] = ["profile": .string(profile)]
            if ![404, 405].contains(snapshotResponse.statusCode) {
                guard (200..<300).contains(snapshotResponse.statusCode) else {
                    throw HermesError.http(snapshotResponse.statusCode, nil)
                }
                let snapshot = JSON.decode(snapshotData) ?? .null
                guard let revision = snapshot["runtime_revision"].double,
                      let generation = snapshot["runtime_generation"].double else { throw HermesError.unsupported }
                identity["request_id"] = .string(UUID().uuidString)
                identity["expected_revision"] = .number(revision)
                identity["expected_generation"] = .number(generation)
            }
            var query: [String: String] = [:]
            if fields == nil {
                for (key, value) in identity {
                    if let text = value.text { query[key] = text }
                    else if let number = value.double { query[key] = String(Int(number)) }
                }
            }
            var body = identity
            fields?.forEach { body[$0.key] = $0.value }
            var req = request(base, path, method: fields == nil ? "DELETE" : "PATCH",
                              body: fields == nil ? nil : .object(body), query: query)
            let (data, response) = try await authorizedRaw(&req)
            guard revision == scopeRevision else { return }
            let json = JSON.decode(data) ?? .null
            let absent = fields == nil && response.statusCode == 404 &&
                (json["already_absent"].flag == true || json["detail"].text == "already_absent")
            if !absent {
                if [404, 405].contains(response.statusCode) { throw HermesError.sessionManagementUnsupported }
                guard (200..<300).contains(response.statusCode) else {
                    throw HermesError.http(response.statusCode, json["detail"].text)
                }
            }
            if fields == nil {
                invalidateChat(chat.id)
            }
        } catch {
            guard revision == scopeRevision else { return }
            sessions.removeAll { $0.id == chat.id }
            sessions.append(original)
            cache.store(sessions: sessions)
            throw error
        }
    }

    /// The chat already running for this key, or a fresh one that loads its history.
    func liveChat(for key: String?) -> LiveChat {
        guard let key else {
            unsavedChats.removeAll { $0.chat == nil || $0.chat?.key != nil }
            let chat = LiveChat(key: nil)
            unsavedChats.append(ChatReference(chat))
            return chat
        }
        if let chat = retainedRoutes[key]?.chat { return chat }
        retainedRoutes = retainedRoutes.filter { $0.value.chat != nil }
        let chat = LiveChat(key: key)
        retainedRoutes[key] = ChatReference(chat)
        return chat
    }

    func keepLive(_ chat: LiveChat, as key: String) {
        retainedRoutes[key] = ChatReference(chat)
        liveChats[key] = chat
    }

    func invalidateChat(_ key: String) {
        deletedSessionKeys.insert(key)
        retainedRoutes[key]?.chat?.shutDown()
        retainedRoutes[key] = nil
        liveChats[key] = nil
        sessions.removeAll { $0.id == key }
        replyingKeys.remove(key)
        cache.removeSession(key)
    }

    func releaseLive(_ chat: LiveChat, key: String) {
        if liveChats[key] === chat { liveChats[key] = nil }
    }

    private func shutDownLiveChats() {
        scopeRevision = UUID()
        pendingSessionKeys = []
        pendingDeletes = []
        replyingKeys = []
        localActivity = [:]
        let chats = retainedRoutes.values.compactMap(\.chat) + unsavedChats.compactMap(\.chat)
        retainedRoutes = [:]
        unsavedChats = []
        liveChats = [:]
        chats.forEach { $0.shutDown() }
    }

    // MARK: REST

    func refreshSessions() async {
        do {
            try await ensureSignedIn()
            let revision = scopeRevision
            let json = try await getJSON("api/sessions", query: [
                "profile": profile, "order": "recent", "archived": "exclude", "limit": "100", "offset": "0",
                "min_messages": "1", "exclude_sources": "cron,kanban,oneshot,subagent,tool"
            ])
            guard revision == scopeRevision else { return }
            let local = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
            var fresh: [HermesSession] = (json["sessions"].list ?? []).compactMap { row in
                // A row can be wrapped (`{session: {...}}`) on some releases.
                let r = row["id"].text != nil ? row : row["session"]
                guard let id = r["id"].text, !id.isEmpty, r["hidden"].flag != true else { return nil }
                let title = r["title"].text.flatMap { $0.isEmpty ? nil : $0 }
                    ?? r["preview"].text.flatMap { $0.isEmpty ? nil : String($0.prefix(60)) }
                    ?? "New chat"
                guard !pendingDeletes.contains(id), !deletedSessionKeys.contains(id) else { return nil }
                if pendingSessionKeys.contains(id), let chat = local[id] { return chat }
                let activity = max(r["last_active"].double ?? 0, localActivity[id] ?? 0)
                return HermesSession(id: id, title: title, lastActive: activity == 0 ? nil : activity,
                                     pinned: r["pinned"].flag ?? false)
            }
            for chat in sessions where pendingSessionKeys.contains(chat.id) && !fresh.contains(where: { $0.id == chat.id }) {
                fresh.append(chat)
            }
            sessions = fresh
            cache.store(sessions: sessions)
            didLoadSessions = true
            prefetchRecent()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func messages(for key: String) async throws -> [HermesMessage] {
        let revision = scopeRevision
        try await ensureSignedIn()
        guard revision == scopeRevision else { throw CancellationError() }
        let json: JSON
        do {
            json = try await getJSON("api/sessions/\(key)/messages", query: [
                "profile": profile, "order": "latest", "limit": "100", "offset": "0", "include_compacted": "true"
            ])
        } catch HermesError.http(404, let detail) where detail == "Session not found" && revision == scopeRevision {
            invalidateChat(key)
            throw CancellationError()
        }
        guard revision == scopeRevision, !deletedSessionKeys.contains(key) else { throw CancellationError() }
        var rows = json["messages"].list ?? []
        // `order=latest` pages newest first; show oldest first.
        if let first = rows.first?["id"].double, let last = rows.last?["id"].double, first > last { rows.reverse() }
        var messages = Self.transcript(from: rows)
        // The server doesn't know how fast replies streamed; keep the rates this device measured.
        if let cached = cache.messages(for: key) {
            let rates = Dictionary(cached.compactMap { m in m.rate.map { (m.text, $0) } }) { _, last in last }
            for index in messages.indices where messages[index].role == "assistant" {
                messages[index].rate = rates[messages[index].text]
            }
        }
        cache.store(messages, for: key, lastActive: sessions.first { $0.id == key }?.lastActive)
        return messages
    }

    /// The active profile's SOUL.md (the agent's persona). Empty when the file doesn't exist yet.
    func soul() async throws -> String {
        try await ensureSignedIn()
        return try await getJSON("api/profiles/\(profile)/soul")["content"].text ?? ""
    }

    func saveSoul(_ content: String) async throws {
        try await ensureSignedIn()
        guard let base = baseURL else { throw HermesError.notConfigured }
        var req = request(base, "api/profiles/\(profile)/soul", method: "PUT",
                          body: .object(["content": .string(content)]))
        let (data, response) = try await authorizedRaw(&req)
        guard (200..<300).contains(response.statusCode) else { throw HermesError.http(response.statusCode, Self.detail(data)) }
    }

    /// The conversation as it was last read on this device, for an instant first render.
    func cachedMessages(for key: String) -> [HermesMessage]? {
        cache.messages(for: key)
    }

    /// Saves a conversation the chat screen just changed (a finished turn).
    func cacheMessages(_ messages: [HermesMessage], for key: String) {
        cache.store(messages, for: key, lastActive: sessions.first { $0.id == key }?.lastActive)
    }

    /// Downloads the most recent conversations that aren't on device or are out of date, one at
    /// a time, so opening any of them is instant.
    private func prefetchRecent() {
        prefetchTask?.cancel()
        let targets = sessions.prefix(ConversationCache.limit).filter { cache.isStale($0) }.map(\.id)
        guard !targets.isEmpty else { return }
        prefetchTask = Task { [weak self] in
            for key in targets {
                guard !Task.isCancelled, let self else { return }
                _ = try? await self.messages(for: key)
            }
        }
    }

    private func getJSON(_ path: String, query: [String: String] = [:]) async throws -> JSON {
        guard let base = baseURL else { throw HermesError.notConfigured }
        var req = request(base, path, query: query)
        let (data, response) = try await authorizedRaw(&req)
        guard (200..<300).contains(response.statusCode) else { throw HermesError.http(response.statusCode, Self.detail(data)) }
        guard let json = JSON.decode(data) else { throw HermesError.unsupported }
        return json
    }

    /// Sends a signed-in request; one 401 (an expired cookie or a restarted host) signs in again.
    private func authorizedRaw(_ req: inout URLRequest) async throws -> (Data, HTTPURLResponse) {
        authorize(&req)
        var (data, response) = try await raw(req)
        if response.statusCode == 401 {
            signedIn = false
            try await ensureSignedIn()
            authorize(&req)
            (data, response) = try await raw(req)
        }
        return (data, response)
    }

    private func authorize(_ req: inout URLRequest) {
        if let pageToken { req.setValue(pageToken, forHTTPHeaderField: "X-Hermes-Session-Token") }
    }

    private func request(_ base: URL, _ path: String, method: String = "GET", body: JSON? = nil,
                         query: [String: String] = [:]) -> URLRequest {
        var url = path.isEmpty ? base.appendingPathComponent("/") : base.appendingPathComponent(path)
        if !query.isEmpty, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            parts.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
            parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
            url = parts.url ?? url
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 30
        if let body {
            req.httpBody = body.encoded()
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        applyAccessHeaders(&req)
        return req
    }

    private func applyAccessHeaders(_ req: inout URLRequest) {
        let id = accessClientID.trimmingCharacters(in: .whitespaces)
        let secret = accessClientSecret.trimmingCharacters(in: .whitespaces)
        if !id.isEmpty, !secret.isEmpty {
            req.setValue(id, forHTTPHeaderField: "CF-Access-Client-Id")
            req.setValue(secret, forHTTPHeaderField: "CF-Access-Client-Secret")
        }
    }

    private func raw(_ req: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw HermesError.unsupported }
        return (data, http)
    }

    // MARK: Gateway socket

    /// A fresh, signed-in gateway WebSocket upgrade request.
    func gatewayUpgrade() async throws -> (URLRequest, URLSession) {
        try await ensureSignedIn()
        guard let base = baseURL, var parts = URLComponents(url: base.appendingPathComponent("api/ws"),
                                                           resolvingAgainstBaseURL: false)
        else { throw HermesError.notConfigured }
        parts.scheme = base.scheme == "https" ? "wss" : "ws"
        var ticket: String?
        if let pageToken {
            parts.queryItems = [URLQueryItem(name: "token", value: pageToken)]
        } else {
            var req = request(base, "api/auth/ws-ticket", method: "POST", body: .object([:]))
            let (data, response) = try await authorizedRaw(&req)
            guard (200..<300).contains(response.statusCode) else { throw HermesError.http(response.statusCode, Self.detail(data)) }
            guard let t = JSON.decode(data)?["ticket"].text, !t.isEmpty else { throw HermesError.unsupported }
            ticket = t
        }
        guard let url = parts.url else { throw HermesError.invalidAddress }
        var req = URLRequest(url: url)
        if let ticket {
            req.setValue("hermes-gateway-v1, hermes-gateway-ticket." + ticket, forHTTPHeaderField: "Sec-WebSocket-Protocol")
        }
        applyAccessHeaders(&req)
        return (req, session)
    }

    // MARK: Helpers

    static func pageToken(in page: Data) -> String? {
        guard let html = String(data: page, encoding: .utf8),
              let range = html.range(of: "__HERMES_SESSION_TOKEN__") else { return nil }
        let rest = html[range.upperBound...].drop { $0 == " " || $0 == "=" }
        guard let quote = rest.first, quote == "\"" || quote == "'" else { return nil }
        let body = rest.dropFirst()
        guard let end = body.firstIndex(of: quote) else { return nil }
        let token = String(body[..<end])
        return token.isEmpty ? nil : token
    }

    static func detail(_ data: Data) -> String? {
        guard let json = JSON.decode(data) else { return nil }
        return json["detail"].text ?? json["error"].text ?? json["message"].text
    }

    /// Stored rows to transcript items. An assistant row expands to its reasoning, its text and
    /// its tool calls, in that order; `tool` result rows are dropped, since the call shows already.
    static func transcript(from rows: [JSON]) -> [HermesMessage] {
        var items: [HermesMessage] = []
        func isBlank(_ s: String) -> Bool { s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        for row in rows {
            let role = row["role"].text ?? ""
            guard role == "user" || role == "assistant" else { continue }
            if role == "assistant" {
                let reasoning = row["reasoning"].text ?? row["reasoning_content"].text ?? ""
                if !isBlank(reasoning) { items.append(HermesMessage(role: "reasoning", text: reasoning)) }
            }
            let text = text(of: row["content"])
            if !isBlank(text) { items.append(HermesMessage(role: role, text: text)) }
            for call in row["tool_calls"].list ?? [] {
                guard let tool = HermesToolCall(stored: call) else { continue }
                items.append(HermesMessage(role: "tool", text: "", tool: tool))
            }
        }
        return items
    }

    static func text(of content: JSON) -> String {
        switch content {
        case .string(let s): return s
        case .array(let parts):
            return parts.compactMap { $0.text ?? $0["text"].text }.joined(separator: "\n")
        default: return ""
        }
    }
}
