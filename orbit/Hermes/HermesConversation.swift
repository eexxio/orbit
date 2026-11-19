import Foundation

/// One chat: its own gateway socket, the runtime session it resumed or created, and its turns.
@MainActor
final class HermesConversation {
    /// The stored session key, once the host has one.
    private(set) var storedKey: String?
    private var runtimeID: String?
    private var isCanonical = false
    private var usesLegacyModelChange = false
    private var executionGeneration: Int?
    private let profile: String
    private let initialModel: HermesModelOption?
    private var acceptsReplyEvents = true
    private var socket: URLSessionWebSocketTask?
    private var reader: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    private var connectionID = UUID()
    private var nextID = 0
    private var pending: [Int: CheckedContinuation<JSON, Error>] = [:]

    var onDelta: ((String) -> Void)?
    /// Final text, output-token count, and an error if the host only produced a partial reply.
    var onComplete: ((String?, Int?, String?) -> Void)?
    var onError: ((String) -> Void)?
    var onDisconnect: (() -> Void)?
    var onTitle: ((String) -> Void)?
    var onModel: ((_ name: String, _ provider: String?, _ explicitlyChanged: Bool) -> Void)?
    /// Reply text sealed before a tool call; `alreadyStreamed` means it came as deltas too.
    var onInterim: ((_ text: String, _ alreadyStreamed: Bool) -> Void)?
    /// Thinking text; `replace` swaps the current block's text instead of appending to it.
    var onReasoning: ((_ text: String, _ replace: Bool) -> Void)?
    var onToolStart: ((HermesToolCall) -> Void)?
    var onToolComplete: ((_ id: String, _ summary: String?) -> Void)?

    private let client = HermesClient.shared

    init(storedKey: String?, profile: String, model: HermesModelOption?) {
        self.storedKey = storedKey
        self.profile = profile
        initialModel = model
    }

    func close() {
        connectionID = UUID()
        reader?.cancel(); heartbeat?.cancel()
        reader = nil; heartbeat = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil; runtimeID = nil
        executionGeneration = nil
        failPending(HermesError.socketClosed)
    }

    /// Sends one prompt, opening the socket and session first when needed.
    func send(_ text: String) async throws {
        if socket == nil || runtimeID == nil { try await open() }
        guard let runtimeID else { throw HermesError.unsupported }
        acceptsReplyEvents = true
        var params: [String: JSON] = ["session_id": .string(runtimeID), "text": .string(text), "queued": .bool(true)]
        if isCanonical {
            params["profile"] = .string(profile)
            params["input_id"] = .string(UUID().uuidString)
        }
        let reply = try await call("prompt.submit", params)
        if let generation = reply["execution_generation"].int { executionGeneration = generation }
    }

    func interrupt(timeout: Duration) async -> Bool {
        acceptsReplyEvents = false
        guard let runtimeID else { return false }
        do {
            var params: [String: JSON] = ["session_id": .string(runtimeID)]
            if isCanonical {
                guard let executionGeneration else { return false }
                params["profile"] = .string(profile)
                params["execution_generation"] = .number(Double(executionGeneration))
            }
            _ = try await call("session.interrupt", params, timeout: timeout)
            return true
        } catch {
            return false
        }
    }

    /// Change only this session. Canonical owners fence writes with a fresh revision and generation.
    func changeModel(_ option: HermesModelOption, confirmation: HermesModelConfirmation?) async throws -> HermesModelConfirmation? {
        guard storedKey != nil else { throw HermesError.unsupported }
        if socket == nil || runtimeID == nil { try await open() }
        guard let runtimeID else { throw HermesError.unsupported }
        var reply: JSON?
        if isCanonical && !usesLegacyModelChange {
            do {
                reply = try await mutateModel(option, token: confirmation?.token, sessionID: runtimeID)
            } catch HermesError.rpc(-32601, _) {
                usesLegacyModelChange = true
            }
        }
        let response: JSON
        if let reply { response = reply }
        else { response = try await setLegacyModel(option, confirmed: confirmation != nil, sessionID: runtimeID) }
        if response["confirm_required"].flag == true {
            return HermesModelConfirmation(option: option, message: response["confirm_message"].text
                                           ?? "Hermes requires confirmation to use this model.", token: response["confirm"].text)
        }
        guard let name = (response["model"].text ?? response["value"].text), !name.isEmpty else { throw HermesError.unsupported }
        onModel?(name, response["provider"].text ?? response["info"]["provider"].text ?? option.provider, true)
        return nil
    }

    private func mutateModel(_ option: HermesModelOption, token: String?, sessionID: String) async throws -> JSON {
        var payload: [String: JSON] = ["model": .string(option.name), "provider": .string(option.provider)]
        if let token { payload["confirm"] = .string(token) }
        for attempt in 0..<2 {
            let snapshot = try await call("session.resume", resumeParams(sessionID), timeout: .seconds(5))
            guard snapshot["running"].flag != true else {
                throw HermesError.server("Wait until the chat finishes before changing its model.")
            }
            guard let revision = snapshot["revision"].int, let generation = snapshot["execution_generation"].int
            else { throw HermesError.unsupported }
            let resolved = snapshot["session_id"].text ?? sessionID
            do {
                return try await call("session.mutate", [
                    "profile": .string(profile), "session_id": .string(resolved), "request_id": .string(UUID().uuidString),
                    "expected_revision": .number(Double(revision)), "expected_generation": .number(Double(generation)),
                    "operation": .string("model"), "payload": .object(payload)
                ], timeout: .seconds(15))
            } catch HermesError.modelConflict {
                if attempt == 1 { throw HermesError.modelConflict }
            }
        }
        throw HermesError.modelConflict
    }

    private func setLegacyModel(_ option: HermesModelOption, confirmed: Bool, sessionID: String) async throws -> JSON {
        // The legacy setter parses whitespace-delimited flags. Only pass single safe tokens.
        guard [option.name, option.provider].allSatisfy({ value in
            !value.isEmpty && !value.hasPrefix("-") && value.utf8.allSatisfy { $0 > 32 && $0 < 127 }
        }) else { throw HermesError.unsupported }
        return try await call("config.set", [
            "session_id": .string(sessionID), "key": .string("model"),
            "value": .string("\(option.name) --provider \(option.provider) --session"),
            "confirm_expensive_model": .bool(confirmed)
        ], timeout: .seconds(15))
    }

    func liveModels(refresh: Bool) async throws -> HermesModelCatalog? {
        guard let runtimeID, socket != nil else { return nil }
        do {
            return try HermesModelCatalog(await call("model.options", [
                "profile": .string(profile), "session_id": .string(runtimeID), "refresh": .bool(refresh)
            ], timeout: .seconds(10)))
        } catch HermesError.rpc(-32601, _) {
            return nil
        } catch HermesError.rpc(5098, _) {
            throw HermesError.modelListNeedsRestart
        }
    }

    private func resumeParams(_ key: String) -> [String: JSON] {
        var params: [String: JSON] = ["profile": .string(profile), "session_id": .string(key),
                                      "source": .string("gui"), "omit_messages": .bool(true)]
        if !isCanonical { params["close_on_disconnect"] = .bool(false) }
        return params
    }

    private func open() async throws {
        close()
        let opening = connectionID
        let (upgrade, session) = try await client.gatewayUpgrade()
        guard connectionID == opening else { throw HermesError.socketClosed }
        let task = session.webSocketTask(with: upgrade)
        task.maximumMessageSize = 16 * 1024 * 1024
        task.resume()
        socket = task

        // Handshake: the host's first frame is the `gateway.ready` event.
        let ready = try await Self.receive(task)
        guard socket === task else { throw HermesError.socketClosed }
        guard ready["method"].text == "event", ready["params"]["type"].text == "gateway.ready" else {
            throw HermesError.unsupported
        }
        isCanonical = ready["params"]["payload"]["session_authority"].flag == true
        usesLegacyModelChange = false
        startReader(task)
        startHeartbeat(task)

        let snapshot: JSON
        if let storedKey {
            snapshot = try await call("session.resume", resumeParams(storedKey), timeout: .seconds(20))
        } else {
            var params: [String: JSON] = ["profile": .string(profile), "source": .string("gui")]
            if let initialModel {
                params["model"] = .string(initialModel.name)
                params["provider"] = .string(initialModel.provider)
            }
            snapshot = try await call("session.create", params, timeout: .seconds(30))
        }
        guard socket === task else { throw HermesError.socketClosed }
        guard let runtime = snapshot["session_id"].text, !runtime.isEmpty else { throw HermesError.unsupported }
        runtimeID = runtime
        storedKey = storedKey ?? snapshot["stored_session_id"].text ?? snapshot["info"]["stored_session_id"].text
        executionGeneration = snapshot["execution_generation"].int
        readModel(snapshot["info"])
    }

    private func call(_ method: String, _ params: [String: JSON], timeout: Duration? = nil) async throws -> JSON {
        guard let socket else { throw HermesError.socketClosed }
        nextID += 1
        let id = nextID
        let frame: JSON = .object(["jsonrpc": .string("2.0"), "id": .number(Double(id)),
                                   "method": .string(method), "params": .object(params)])
        var timer: Task<Void, Never>?
        defer { timer?.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            if let timeout {
                timer = Task { [weak self] in
                    do { try await Task.sleep(for: timeout) } catch { return }
                    self?.pending.removeValue(forKey: id)?.resume(throwing: HermesError.socketClosed)
                }
            }
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
                    guard let self, self.socket === task else { return }
                    self.consume(frame)
                }
            } catch {
                guard let self, self.socket === task else { return }
                self.close()
                if self.acceptsReplyEvents { self.onDisconnect?() }
            }
        }
    }

    private func startHeartbeat(_ task: URLSessionWebSocketTask) {
        heartbeat = Task {
            var beat = 0
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
                beat += 1
                try? await task.send(.string(#"{"jsonrpc":"2.0","id":"heartbeat-\#(beat)","method":"gateway.ping","params":{}}"#))
            }
        }
    }

    private func consume(_ frame: JSON) {
        if frame["method"].text == "event" { apply(frame["params"]); return }
        // A server→client request (approvals, questions): this client doesn't advertise
        // `server_requests`, so the host shouldn't send any; answer empty to be safe.
        // JSON-RPC tells requests from responses by `method`; echo the request's id unchanged.
        if frame["method"].text != nil {
            guard frame["id"] != .null else { return }
            let reply: JSON = .object(["jsonrpc": .string("2.0"), "id": frame["id"], "result": .object([:])])
            socket?.send(.string(String(decoding: reply.encoded(), as: UTF8.self))) { _ in }
            return
        }
        guard let id = frame["id"].int, let continuation = pending.removeValue(forKey: id) else { return }
        if frame["error"] != .null {
            let error = frame["error"]
            let message = error["message"].text
            let reason = error["data"]["reason"].text ?? message
            if ["profile_mismatch", "profile_unavailable"].contains(reason) {
                continuation.resume(throwing: HermesError.profileGone)
            } else if ["revision_conflict", "stale_generation"].contains(reason) {
                continuation.resume(throwing: HermesError.modelConflict)
            } else {
                let detail = error["data"]["detail"].text
                    ?? (message?.contains("_") == false ? message : nil)
                    ?? "The server refused the request."
                continuation.resume(throwing: HermesError.rpc(error["code"].int, detail))
            }
        } else {
            continuation.resume(returning: frame["result"])
        }
    }

    private func apply(_ event: JSON) {
        if let session = event["session_id"].text, let runtimeID, session != runtimeID { return }
        if let generation = event["execution_generation"].int { executionGeneration = generation }
        guard acceptsReplyEvents || ["session.info", "session.title", "session.updated"].contains(event["type"].text ?? "") else { return }
        let payload = event["payload"]
        switch event["type"].text ?? "" {
        case "message.delta":
            if let text = payload["text"].text, !text.isEmpty { onDelta?(text) }
        case "message.interim":
            if let text = payload["text"].text, !text.isEmpty { onInterim?(text, payload["already_streamed"].flag == true) }
        // `thinking.delta` is spinner and wait-notice text, not the model's reasoning: left out.
        case "reasoning.delta", "reasoning.available":
            if let text = payload["text"].text, !text.isEmpty { onReasoning?(text, event["type"].text == "reasoning.available") }
        case "tool.start":
            guard let id = payload["tool_id"].text, let name = payload["name"].text else { return }
            onToolStart?(HermesToolCall(id: id, name: name, context: payload["context"].text ?? "",
                                        summary: nil, isDone: false))
        case "tool.complete":
            if let id = payload["tool_id"].text { onToolComplete?(id, payload["summary"].text) }
        case "message.complete":
            if event["admission_id"].text != nil, event["execution_generation"] == .null { return }
            if payload["status"].text == "error" {
                if payload["partial"].flag == true {
                    onComplete?(payload["text"].text, Self.outputTokens(payload),
                                payload["error"].text ?? "The server couldn't finish the reply.")
                } else {
                    onError?(payload["text"].text ?? payload["error"].text ?? "The turn failed.")
                }
            } else {
                onComplete?(payload["text"].text, Self.outputTokens(payload), nil)
            }
        case "error":
            onError?(payload["message"].text ?? "The turn failed.")
        case "session.title":
            if let title = payload["title"].text, !title.isEmpty { onTitle?(title) }
        case "session.info":
            if let key = payload["stored_session_id"].text, !key.isEmpty, storedKey == nil { storedKey = key }
            readModel(payload)
        case "session.updated":
            if payload["operation"].text == "model" { readModel(payload) }
        default:
            break
        }
    }

    private func readModel(_ info: JSON) {
        if let name = info["model"].text, !name.isEmpty { onModel?(name, info["provider"].text, false) }
    }

    /// Output tokens for the turn, if the host says. Hermes releases and providers name
    /// this differently (OpenAI- vs Anthropic-style usage), so try the common spellings.
    private static func outputTokens(_ payload: JSON) -> Int? {
        for usage in [payload["usage"], payload["info"]["usage"], payload] {
            for key in ["output_tokens", "completion_tokens", "outputTokens", "completionTokens"] {
                if let n = usage[key].int, n > 0 { return n }
            }
        }
        return nil
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
