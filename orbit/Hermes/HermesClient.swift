import Foundation
import Observation

// The Hermes Agent dashboard endpoints this client talks to:
//   • GET  /api/status                 – public; tells us how to sign in
//   • POST /auth/password-login        – username/password, sets a session cookie
//   • GET  /                           – an open dashboard's page carries its session token
//   • GET  /api/profiles/active        – `{current}` profile name
//   • GET  /api/sessions               – session list
//   • GET  /api/sessions/{key}/messages – transcript
//   • POST /api/auth/ws-ticket         – single-use ticket for the gateway socket
//   • WS   /api/ws                     – JSON-RPC 2.0 gateway: session.create / session.resume /
//                                        prompt.submit, streaming `message.delta` events.

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

    @ObservationIgnored private(set) var cache: ConversationCache
    @ObservationIgnored private var prefetchTask: Task<Void, Never>?
    @ObservationIgnored private var session = URLSession(configuration: .ephemeral)
    @ObservationIgnored private var pageToken: String?
    @ObservationIgnored private var signedIn = false
    @ObservationIgnored private var signInTask: Task<Void, Error>?

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
            if let active = try? await getJSON("api/profiles/active"), let current = active["current"].text, !current.isEmpty {
                profile = current
            }
            state = .connected
        } catch {
            signedIn = false
            state = .failed(error.localizedDescription)
            throw error
        }
    }

    // MARK: REST

    func refreshSessions() async {
        do {
            try await ensureSignedIn()
            let json = try await getJSON("api/sessions", query: [
                "profile": profile, "order": "recent", "archived": "exclude", "limit": "100", "offset": "0",
                "min_messages": "1", "exclude_sources": "cron,kanban,oneshot,subagent,tool"
            ])
            sessions = (json["sessions"].list ?? []).compactMap { row in
                // A row can be wrapped (`{session: {...}}`) on some releases.
                let r = row["id"].text != nil ? row : row["session"]
                guard let id = r["id"].text, !id.isEmpty, r["hidden"].flag != true else { return nil }
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

    func messages(for key: String) async throws -> [HermesMessage] {
        try await ensureSignedIn()
        let json = try await getJSON("api/sessions/\(key)/messages", query: [
            "profile": profile, "order": "latest", "limit": "100", "offset": "0", "include_compacted": "true"
        ])
        var rows = json["messages"].list ?? []
        // `order=latest` pages newest first; show oldest first.
        if let first = rows.first?["id"].double, let last = rows.last?["id"].double, first > last { rows.reverse() }
        let messages: [HermesMessage] = rows.compactMap { row in
            guard let role = row["role"].text, role == "user" || role == "assistant" else { return nil }
            let text = Self.text(of: row["content"])
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return HermesMessage(role: role, text: text)
        }
        cache.store(messages, for: key, lastActive: sessions.first { $0.id == key }?.lastActive)
        return messages
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

    static func text(of content: JSON) -> String {
        switch content {
        case .string(let s): return s
        case .array(let parts):
            return parts.compactMap { $0.text ?? $0["text"].text }.joined(separator: "\n")
        default: return ""
        }
    }
}
