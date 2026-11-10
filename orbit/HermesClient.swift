import Foundation
import Observation
import Security

// A compact port of the Hermes Agent dashboard backend that the Hermex iOS app
// (github.com/uzairansaruzi/hermex) talks to:
//   • GET  /api/status                 – public; tells us how to sign in
//   • POST /auth/password-login        – username/password, sets a session cookie
//   • GET  /                           – an open dashboard's page carries its session token
//   • GET  /api/profiles/active        – `{current}` profile name
//   • GET  /api/sessions               – session list
//   • GET  /api/sessions/{key}/messages – transcript
//   • POST /api/auth/ws-ticket         – single-use ticket for the gateway socket
//   • WS   /api/ws                     – JSON-RPC 2.0 gateway: session.create / session.resume /
//                                        prompt.submit, streaming `message.delta` events.

// MARK: - JSON

enum JSON: Codable, Equatable, Sendable {
    case string(String), number(Double), bool(Bool), object([String: JSON]), array([JSON]), null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSON].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSON].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }

    subscript(key: String) -> JSON {
        if case .object(let o) = self { return o[key] ?? .null }
        return .null
    }

    var text: String? {
        switch self {
        case .string(let s): return s
        case .number(let n): return n == n.rounded() ? String(Int(n)) : String(n)
        default: return nil
        }
    }
    var double: Double? {
        switch self {
        case .number(let n): return n
        case .string(let s): return Double(s)
        default: return nil
        }
    }
    var int: Int? { double.map { Int($0) } }
    var flag: Bool? { if case .bool(let b) = self { return b }; return nil }
    var list: [JSON]? { if case .array(let a) = self { return a }; return nil }

    static func decode(_ data: Data) -> JSON? { try? JSONDecoder().decode(JSON.self, from: data) }
    func encoded() -> Data { (try? JSONEncoder().encode(self)) ?? Data() }
}

// MARK: - Errors

enum HermesError: LocalizedError {
    case notConfigured, invalidAddress, notDashboard, wrongPassword, browserOnly
    case http(Int, String?), unsupported, socketClosed, server(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Add your Hermes server in Settings."
        case .invalidAddress: return "That server address isn't valid."
        case .notDashboard: return "That address didn't answer like a Hermes dashboard."
        case .wrongPassword: return "The username or password was rejected."
        case .browserOnly: return "This dashboard only allows browser sign-in. Enable Username & password on the host."
        case .http(let code, let detail): return detail.map { "Server error \(code): \($0)" } ?? "Server error \(code)."
        case .unsupported: return "The server sent a reply this app doesn't understand."
        case .socketClosed: return "The connection to the server was lost."
        case .server(let message): return message
        }
    }
}

// MARK: - Models

struct HermesSession: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let title: String
    let lastActive: Double?
}

struct HermesMessage: Codable, Sendable {
    let role: String
    let text: String
}

// MARK: - Keychain

private enum Keychain {
    static let service = "orbit.hermes"

    static func read(_ account: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service, kSecAttrAccount as String: account,
                                    kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ value: String, _ account: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
}

// MARK: - Client

@MainActor @Observable
final class HermesClient {
    static let shared = HermesClient()

    enum State: Equatable { case disconnected, connecting, connected, failed(String) }

    // Saved configuration
    var address: String { didSet { UserDefaults.standard.set(address, forKey: "hermes.address") } }
    var username: String { didSet { UserDefaults.standard.set(username, forKey: "hermes.username") } }
    var password: String { didSet { Keychain.write(password, "password") } }
    /// Optional Cloudflare Access service token, as Hermex supports for Cloudflare Tunnel.
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

// MARK: - Chat conversation over the gateway

/// One chat: its own gateway socket, the runtime session it resumed or created, and its turns.
@MainActor
final class HermesConversation {
    /// The stored session key, once the host has one.
    private(set) var storedKey: String?
    private var runtimeID: String?
    private var socket: URLSessionWebSocketTask?
    private var reader: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    private var nextID = 0
    private var pending: [Int: CheckedContinuation<JSON, Error>] = [:]

    var onDelta: ((String) -> Void)?
    var onComplete: ((String?) -> Void)?
    var onError: ((String) -> Void)?
    var onTitle: ((String) -> Void)?

    private let client = HermesClient.shared

    init(storedKey: String?) { self.storedKey = storedKey }

    func close() {
        reader?.cancel(); heartbeat?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil; runtimeID = nil
        failPending(HermesError.socketClosed)
    }

    /// Sends one prompt, opening the socket and session first when needed.
    func send(_ text: String) async throws {
        if socket == nil || runtimeID == nil { try await open() }
        guard let runtimeID else { throw HermesError.unsupported }
        _ = try await call("prompt.submit", ["session_id": .string(runtimeID), "text": .string(text), "queued": .bool(true)])
    }

    func interrupt() async {
        guard let runtimeID else { return }
        _ = try? await call("session.interrupt", ["session_id": .string(runtimeID)])
    }

    private func open() async throws {
        close()
        let (upgrade, session) = try await client.gatewayUpgrade()
        let task = session.webSocketTask(with: upgrade)
        task.maximumMessageSize = 16 * 1024 * 1024
        task.resume()
        socket = task

        // Handshake: the host's first frame is the `gateway.ready` event.
        let ready = try await Self.receive(task)
        guard ready["method"].text == "event", ready["params"]["type"].text == "gateway.ready" else {
            throw HermesError.unsupported
        }
        startReader(task)
        startHeartbeat(task)

        let profile = client.profile
        if let storedKey {
            let reply = try await call("session.resume", ["profile": .string(profile), "session_id": .string(storedKey),
                                                          "close_on_disconnect": .bool(false), "source": .string("gui"),
                                                          "omit_messages": .bool(true)])
            guard let runtime = reply["session_id"].text, !runtime.isEmpty else { throw HermesError.unsupported }
            runtimeID = runtime
        } else {
            let reply = try await call("session.create", ["profile": .string(profile), "source": .string("gui")])
            guard let runtime = reply["session_id"].text, !runtime.isEmpty else { throw HermesError.unsupported }
            runtimeID = runtime
            storedKey = reply["stored_session_id"].text ?? reply["info"]["stored_session_id"].text
        }
    }

    private func call(_ method: String, _ params: [String: JSON]) async throws -> JSON {
        guard let socket else { throw HermesError.socketClosed }
        nextID += 1
        let id = nextID
        let frame: JSON = .object(["jsonrpc": .string("2.0"), "id": .number(Double(id)),
                                   "method": .string(method), "params": .object(params)])
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            let data = String(decoding: frame.encoded(), as: UTF8.self)
            socket.send(.string(data)) { [weak self] error in
                guard let error else { return }
                Task { @MainActor in self?.pending.removeValue(forKey: id)?.resume(throwing: error) }
            }
        }
    }

    private func startReader(_ task: URLSessionWebSocketTask) {
        reader = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    let frame = try await Self.receive(task)
                    self?.consume(frame)
                }
            } catch {
                guard let self, self.socket === task else { return }
                self.socket = nil
                self.runtimeID = nil
                self.failPending(HermesError.socketClosed)
            }
        }
    }

    private func startHeartbeat(_ task: URLSessionWebSocketTask) {
        heartbeat = Task {
            var beat = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                beat += 1
                try? await task.send(.string(#"{"jsonrpc":"2.0","id":"heartbeat-\#(beat)","method":"gateway.ping","params":{}}"#))
            }
        }
    }

    private func consume(_ frame: JSON) {
        if frame["method"].text == "event" { apply(frame["params"]); return }
        // A server→client request (approvals, questions): this client doesn't advertise
        // `server_requests`, so the host shouldn't send any; answer empty to be safe.
        if let id = frame["id"].text, frame["method"].text != nil, frame["id"].int == nil {
            let reply: JSON = .object(["jsonrpc": .string("2.0"), "id": .string(id), "result": .object([:])])
            socket?.send(.string(String(decoding: reply.encoded(), as: UTF8.self))) { _ in }
            return
        }
        guard let id = frame["id"].int, let continuation = pending.removeValue(forKey: id) else { return }
        if frame["error"] != .null {
            continuation.resume(throwing: HermesError.server(frame["error"]["message"].text ?? "The server refused the request."))
        } else {
            continuation.resume(returning: frame["result"])
        }
    }

    private func apply(_ event: JSON) {
        if let session = event["session_id"].text, let runtimeID, session != runtimeID { return }
        let payload = event["payload"]
        switch event["type"].text ?? "" {
        case "message.delta":
            if let text = payload["text"].text, !text.isEmpty { onDelta?(text) }
        case "message.complete":
            if event["admission_id"].text != nil, event["execution_generation"] == .null { return }
            if payload["status"].text == "error", payload["partial"].flag != true {
                onError?(payload["text"].text ?? payload["error"].text ?? "The turn failed.")
            } else {
                onComplete?(payload["text"].text)
            }
        case "error":
            if let message = payload["message"].text, !message.isEmpty { onError?(message) }
        case "session.title":
            if let title = payload["title"].text, !title.isEmpty { onTitle?(title) }
        case "session.info":
            if let key = payload["stored_session_id"].text, !key.isEmpty, storedKey == nil { storedKey = key }
        default:
            break
        }
    }

    private func failPending(_ error: Error) {
        let all = pending.values
        pending.removeAll()
        all.forEach { $0.resume(throwing: error) }
    }

    nonisolated private static func receive(_ task: URLSessionWebSocketTask) async throws -> JSON {
        switch try await task.receive() {
        case .string(let s): return JSON.decode(Data(s.utf8)) ?? .null
        case .data(let d): return JSON.decode(d) ?? .null
        @unknown default: return .null
        }
    }
}
