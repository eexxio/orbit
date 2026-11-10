import Foundation

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
