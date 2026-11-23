import Foundation
import Observation
import CryptoKit

// The Hermes Agent dashboard endpoints this client talks to:
//   • GET  /api/status                 – public; tells us how to sign in
//   • POST /auth/password-login        – username/password, sets a session cookie
//   • GET  /                           – an open dashboard's page carries its session token
//   • GET  /api/profiles/active        – `{current}` profile name
//   • GET  /api/sessions               – session list
//   • GET  /api/sessions/{key}         – verify the selected Shortcut chat
//   • GET  /api/sessions/{key}/messages – transcript
//   • GET  /api/profiles/{name}/soul   – `{content, exists}`: the profile's SOUL.md
//   • PUT  /api/profiles/{name}/soul   – `{content}` replaces SOUL.md
//   • POST /api/auth/ws-ticket         – single-use ticket for the gateway socket
//   • WS   /api/ws                     – JSON-RPC 2.0 gateway: session.create / session.resume /
//                                        prompt.submit / prompt.receipt / session.interrupt, streaming `message.delta` / `message.interim` /
//                                        `message.complete`, `reasoning.delta` / `reasoning.available`,
//                                        and `tool.start` / `tool.complete` events.

// MARK: - Client

@MainActor @Observable
final class HermesClient {
    static let shared = HermesClient()

    enum State: Equatable { case disconnected, connecting, connected, failed(String) }

    // Saved configuration
    var address: String { didSet { settingsRevision = UUID(); UserDefaults.standard.set(address, forKey: "hermes.address") } }
    var username: String { didSet { settingsRevision = UUID(); UserDefaults.standard.set(username, forKey: "hermes.username") } }
    var password: String { didSet { settingsRevision = UUID(); Keychain.write(password, "password") } }
    /// Optional Cloudflare Access service token, for dashboards behind Cloudflare Tunnel.
    var accessClientID: String { didSet { settingsRevision = UUID(); UserDefaults.standard.set(accessClientID, forKey: "hermes.cfid") } }
    var accessClientSecret: String { didSet { settingsRevision = UUID(); Keychain.write(accessClientSecret, "cfsecret") } }
    @ObservationIgnored private(set) var settingsRevision = UUID()
    @ObservationIgnored private var signedInRevision: UUID?
    @ObservationIgnored private var validatedProfileRevision: UUID?

    private(set) var state: State = .disconnected
    private(set) var serverVersion: String?
    private(set) var profile = "default"
    private(set) var sessions: [HermesSession] = []

    @ObservationIgnored private(set) var cache: ConversationCache
    @ObservationIgnored private var prefetchTask: Task<Void, Never>?
    @ObservationIgnored private var session = URLSession(configuration: .ephemeral)
    @ObservationIgnored private var pageToken: String?
    @ObservationIgnored private var signedIn = false
    @ObservationIgnored private var signInTask: Task<Void, Error>?
    /// Chats with a turn running or a screen showing them, by session key, so leaving a chat
    /// mid-reply doesn't drop it. Not observed: views watch the `LiveChat` itself.
    @ObservationIgnored private var liveChats: [String: LiveChat] = [:]
    var shortcutChatReservation: String?
    @ObservationIgnored var shortcutInProgress = false
    @ObservationIgnored private(set) var shortcutSessions: (scope: String, chats: [HermesSession])?

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

    /// Drops any sign-in and connects again with the current settings.
    func connect() async {
        shutDownLiveChats()
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
        shutDownLiveChats()
        signOutLocally()
        cache.clear()
        sessions = []
        state = .disconnected
    }

    private func signOutLocally() {
        shortcutSessions = nil
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
        if signedIn, signedInRevision == settingsRevision { return }
        if let task = signInTask { return try await task.value }
        let task = Task { try await self.performSignIn() }
        signInTask = task
        defer {
            if signInTask == task { signInTask = nil }
        }
        try await task.value
    }

    private func performSignIn() async throws {
        guard let base = baseURL else { throw HermesError.notConfigured }
        let revision = settingsRevision
        state = .connecting
        do {
            pageToken = nil
            let (statusData, statusResponse) = try await raw(request(base, "api/status"))
            if [401, 403].contains(statusResponse.statusCode) { throw HermesError.wrongPassword }
            guard statusResponse.statusCode == 200, let status = JSON.decode(statusData),
                  status["auth_required"].flag != nil else { throw HermesError.notDashboard }
            try Task.checkCancellation()
            guard settingsRevision == revision else { throw CancellationError() }
            serverVersion = status["version"].text

            if status["auth_required"].flag == false {
                // An open dashboard: its page carries the token every /api route checks.
                let (page, response) = try await raw(request(base, ""))
                if [401, 403].contains(response.statusCode) { throw HermesError.wrongPassword }
                guard let token = Self.pageToken(in: page) else { throw HermesError.notDashboard }
                try Task.checkCancellation()
                guard settingsRevision == revision else { throw CancellationError() }
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
            try Task.checkCancellation()
            guard settingsRevision == revision else { throw CancellationError() }
            var active = request(base, "api/profiles/active")
            authorize(&active)
            let profileResponse = try? await raw(active)
            try Task.checkCancellation()
            guard settingsRevision == revision else { throw CancellationError() }
            if let (data, response) = profileResponse, response.statusCode == 200,
               let current = JSON.decode(data)?["current"].text, !current.isEmpty {
                profile = current
                validatedProfileRevision = revision
            } else {
                validatedProfileRevision = nil
                profile = "default"
            }
            signedIn = true
            signedInRevision = revision
            state = .connected
        } catch {
            if !Task.isCancelled, settingsRevision == revision {
                signedIn = false
                state = .failed(error.localizedDescription)
            }
            throw error
        }
    }

    func ensureShortcutSignIn(refreshProfile: Bool = false) async throws {
        let alreadyValidated = hasValidatedShortcutScope
        try await ensureSignedIn()
        if !hasValidatedShortcutScope || (refreshProfile && alreadyValidated) {
            let active = try await getJSON("api/profiles/active")
            guard let current = active["current"].text, !current.isEmpty,
                  signedInRevision == settingsRevision else { throw HermesError.unsupported }
            profile = current
            validatedProfileRevision = settingsRevision
        }
    }

    var hasValidatedShortcutScope: Bool {
        signedIn && validatedProfileRevision == settingsRevision && signedInRevision == settingsRevision
    }

    // MARK: Live chats

    /// The chat already running for this key, or a fresh one that loads its history.
    func liveChat(for key: String?) -> LiveChat {
        if let key, let live = liveChats[key] { return live }
        return LiveChat(key: key)
    }

    func keepLive(_ chat: LiveChat, as key: String) { liveChats[key] = chat }

    func releaseLive(_ chat: LiveChat, key: String) {
        if liveChats[key] === chat { liveChats[key] = nil }
    }

    func isChatGenerating(_ key: String) -> Bool { liveChats[key]?.isGenerating == true }

    private func shutDownLiveChats() {
        let chats = liveChats.values
        liveChats = [:]
        chats.forEach { $0.shutDown() }
    }

    // MARK: REST

    func refreshSessions() async {
        do {
            try await ensureSignedIn()
            let rows = try await readVisibleSessionRows()
            sessions = rows.compactMap { r in
                guard let id = r["id"].text else { return nil }
                let title = r["title"].text.flatMap { $0.isEmpty ? nil : $0 }
                    ?? r["preview"].text.flatMap { $0.isEmpty ? nil : String($0.prefix(60)) }
                    ?? "New chat"
                return HermesSession(id: id, title: title, lastActive: r["last_active"].double)
            }
            cache.store(sessions: sessions)
            prefetchRecent()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    var shortcutAccount: String {
        let identity = [baseURL?.absoluteString ?? "", username, accessClientID]
            .map { "\($0.utf8.count):\($0)" }.joined()
        return SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    var shortcutScope: String { shortcutAccount + ":" + profile }

    func refreshShortcutSessions() async throws -> [HermesSession] {
        try await ensureShortcutSignIn()
        _ = try await readVisibleSessionRows()
        return shortcutSessions?.chats ?? []
    }

    func validateShortcutChat(_ key: String, requireMessages: Bool = false) async throws -> Bool {
        try await ensureShortcutSignIn()
        guard key.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil else { return false }
        do {
            let response = try await getJSON("api/sessions/\(key)", query: ["profile": profile])
            let row = response["session"] == .null ? response : response["session"]
            return row["id"].text == key && Self.isVisibleSession(row)
                && row["profile"].text.map { $0 == profile } != false
                && (!requireMessages || row["message_count"].int != 0)
        } catch HermesError.http(404, _) {
            return false
        }
    }

    private func readVisibleSessionRows() async throws -> [JSON] {
        let scope = shortcutScope
        let json = try await getJSON("api/sessions", query: [
            "profile": profile, "order": "recent", "archived": "exclude", "limit": "100", "offset": "0",
            "min_messages": "1", "exclude_sources": "cron,kanban,oneshot,subagent,tool"
        ])
        guard scope == shortcutScope else { throw HermesError.notConfigured }
        let rows = (json["sessions"].list ?? [])
            .map { $0["id"].text != nil ? $0 : $0["session"] }
            .filter(Self.isVisibleSession)
        _ = updateShortcutSessions(rows, scope: scope)
        return rows
    }

    private func updateShortcutSessions(_ rows: [JSON], scope: String) -> [HermesSession] {
        let chats = rows.compactMap { row -> HermesSession? in
            guard let id = row["id"].text else { return nil }
            let title = row["title"].text.flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled chat"
            return HermesSession(id: id, title: title,
                                 lastActive: row["last_active"].double ?? row["last_active_at"].double)
        }
        shortcutSessions = (scope, chats)
        return chats
    }

    private static func isVisibleSession(_ row: JSON) -> Bool {
        guard let id = row["id"].text, !id.isEmpty,
              row["hidden"].flag != true, row["hidden"].int != 1,
              row["archived"].flag != true, row["archived"].int != 1 else { return false }
        return !["cron", "kanban", "oneshot", "subagent", "tool"].contains(row["source"].text ?? "")
    }

    func messages(for key: String) async throws -> [HermesMessage] {
        try await ensureSignedIn()
        let json = try await getJSON("api/sessions/\(key)/messages", query: [
            "profile": profile, "order": "latest", "limit": "100", "offset": "0", "include_compacted": "true"
        ])
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
        let revision = settingsRevision
        authorize(&req)
        var (data, response) = try await raw(req)
        if response.statusCode == 401 {
            guard settingsRevision == revision else { throw CancellationError() }
            signedIn = false
            try await ensureSignedIn()
            guard settingsRevision == revision else { throw CancellationError() }
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
