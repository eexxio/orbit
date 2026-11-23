import Foundation
import UIKit

@MainActor
final class HermesShortcutTurn {
    private let client = HermesClient.shared
    private let conversation: HermesConversation
    private let existing: HermesChatEntity?
    private let clock = ContinuousClock()
    private let setupDeadline: ContinuousClock.Instant
    private let replyDeadline: ContinuousClock.Instant
    private var scope: String?
    private var revision: UUID?
    private var sent = false
    private var receipt: JSON?
    private var buffered: [JSON] = []
    private var bufferedBytes = 0
    private var missedEarlyDelta = false
    private var missingDeltas = false
    private var generation: Int?
    private var lastSequence: Int?
    private var replayEpoch: String?
    private var segment: Int?
    private var deltas = ""
    private var completion: AsyncStream<HermesAskOutcome>.Continuation?

    init(existing: HermesChatEntity?) {
        self.existing = existing
        conversation = HermesConversation(storedKey: existing?.key)
        let start = ContinuousClock.now
        setupDeadline = start + .seconds(8)
        replyDeadline = start + .seconds(22)
    }

    func run(_ prompt: String, waiting: @escaping () -> Void) async throws -> HermesAskOutcome {
        try Task.checkCancellation()
        guard !client.shortcutInProgress else {
            return outcome(.busy, "Another Hermes request is already running. Your question wasn’t sent.", route: .chats)
        }
        client.shortcutInProgress = true
        defer {
            client.shortcutInProgress = false
            client.shortcutChatReservation = nil
            conversation.close()
        }
        let (results, continuation) = AsyncStream<HermesAskOutcome>.makeStream(bufferingPolicy: .bufferingOldest(1))
        completion = continuation
        conversation.observeFrame = { [weak self] frame in self?.receive(frame) ?? true }
        conversation.onDisconnect = { [weak self] in self?.disconnected() }

        let work = Task { await self.send(prompt, waiting: waiting) }
        let setupTimer = Task {
            do { try await clock.sleep(until: setupDeadline) } catch { return }
            if !sent { finish(outcome(.unreachable, route: .settings)) }
        }
        let replyTimer = Task {
            do { try await clock.sleep(until: replyDeadline) } catch { return }
            expire()
        }
        defer {
            completion = nil
            work.cancel()
            setupTimer.cancel()
            replyTimer.cancel()
        }
        var iterator = results.makeAsyncIterator()
        let result = await iterator.next()
        try Task.checkCancellation()
        guard let result else { throw CancellationError() }
        return result
    }

    private func send(_ prompt: String, waiting: () -> Void) async {
        let account = client.shortcutAccount
        let revision = client.settingsRevision
        self.revision = revision
        do {
            try await client.ensureShortcutSignIn(refreshProfile: true)
            try Task.checkCancellation()
            let currentScope = client.shortcutScope
            scope = currentScope
            if let existing {
                guard existing.scope == currentScope else {
                    finish(outcome(.chatUnavailable, route: .chats))
                    return
                }
                guard try await client.validateShortcutChat(existing.key, requireMessages: true) else {
                    finish(outcome(.chatUnavailable, route: .chats))
                    return
                }
                if client.isChatGenerating(existing.key) {
                    finish(outcome(.busy, "This chat is already waiting for Hermes. Your question wasn’t sent."))
                    return
                }
                client.shortcutChatReservation = existing.key
            }
            try Task.checkCancellation()
            let snapshot = try await conversation.open(forShortcut: true)
            try Task.checkCancellation()
            guard completion != nil, clock.now < setupDeadline else {
                finish(outcome(.unreachable, route: .settings))
                return
            }
            guard account == client.shortcutAccount, revision == client.settingsRevision, currentScope == client.shortcutScope else {
                finish(outcome(.chatUnavailable, route: .chats))
                return
            }
            if let existing {
                guard conversation.storedKey == existing.key,
                      snapshot["info"]["profile_name"].text.map({ $0 == client.profile }) != false else {
                    finish(outcome(.chatUnavailable, route: .chats))
                    return
                }
                if Self.hasInput(snapshot) {
                    finish(outcome(.needsInput))
                    return
                }
                if snapshot["running"].flag == true || !(snapshot["pending"].list ?? []).isEmpty {
                    finish(outcome(.busy, "This chat is already waiting for Hermes. Your question wasn’t sent."))
                    return
                }
                guard snapshot["running"].flag == false,
                      conversation.usesSessionAuthority
                        ? (snapshot["pending"].list != nil && snapshot["prompts"].list != nil)
                        : (snapshot["status"].text == "idle" && snapshot["inflight"] == .null)
                else {
                    finish(outcome(.busy, "Open the chat in orbit to send your question."))
                    return
                }
            }
            guard UIApplication.shared.isProtectedDataAvailable else { throw CancellationError() }
            lastSequence = snapshot["last_sequence"].int
            replayEpoch = snapshot["replay_epoch"].text
            sent = true
            waiting()
            let reply = try await conversation.submit(prompt)
            guard completion != nil else { return }
            if conversation.usesSessionAuthority {
                guard let admission = reply["admission_id"].text, !admission.isEmpty,
                      ["queued", "started", "terminal"].contains(reply["status"].text ?? ""),
                      reply["ref"]["session_id"].text.map({ $0 == conversation.storedKey }) != false else {
                    finish(outcome(.deliveryUnknown))
                    return
                }
                generation = reply["execution_generation"].int
            } else {
                switch reply["status"].text {
                case "queued": receipt = reply; finish(outcome(.queued)); return
                case "streaming": break
                default: finish(outcome(.deliveryUnknown)); return
                }
            }
            receipt = reply
            let early = buffered
            buffered.removeAll()
            for frame in early { _ = receive(frame) }
        } catch is CancellationError {
            completion?.finish()
        } catch {
            if sent {
                if case HermesConversation.Refusal.rejected = error {
                    finish(outcome(.failed, "Hermes couldn’t accept your question. It wasn’t sent.",
                                   route: existing == nil ? .chats : nil))
                } else {
                    finish(outcome(.deliveryUnknown))
                }
            } else {
                finish(Self.connectionFailure(error))
            }
        }
    }

    private func receive(_ frame: JSON) -> Bool {
        guard let method = frame["method"].text else { return false }
        guard sent, completion != nil else { return true }
        guard clock.now < replyDeadline else { expire(); return true }
        let event = frame["params"]
        let type = event["type"].text
        let payload = event["payload"]
        let runtime = event["session_id"].text ?? payload["session_id"].text
        guard let expected = conversation.runtimeID, runtime == expected else { return true }
        guard revision == client.settingsRevision, scope == client.shortcutScope else {
            finish(outcome(.deliveryUnknown))
            return true
        }
        if type == "session.info", let key = payload["stored_session_id"].text ?? payload["session_key"].text {
            conversation.noteStoredKey(key)
        }
        let input = (method != "event" && frame["id"] != .null)
            || ["approval.request", "clarify.request", "sudo.request", "secret.request"].contains(type)
        if type == "session.replay_gap" { finish(outcome(.deliveryUnknown)); return true }
        guard input || ["message.start", "message.delta", "message.interim", "message.complete", "error"].contains(type) else { return true }
        guard let receipt else {
            if type == "message.delta" {
                bufferedBytes += payload["text"].text?.utf8.count ?? 0
                guard buffered.count < 128, bufferedBytes <= 128 * 1024 else {
                    missedEarlyDelta = true
                    return true
                }
            }
            if buffered.count < 256 { buffered.append(frame) }
            return true
        }
        if conversation.usesSessionAuthority {
            let admission = event["admission_id"].text ?? payload["admission_id"].text
            if !input || admission != nil {
                guard admission == receipt["admission_id"].text,
                      let frameGeneration = event["execution_generation"].int ?? payload["execution_generation"].int,
                      generation == nil || generation == frameGeneration else { return true }
                generation = frameGeneration
            }
            if let sequence = event["seq"].int {
                let epoch = event["replay_epoch"].text
                if epoch == replayEpoch, let lastSequence, sequence <= lastSequence { return true }
                lastSequence = sequence
                replayEpoch = epoch
            }
        }
        if input { finish(outcome(.needsInput)); return true }
        let frameSegment = payload["segment"].int
        if type == "message.start" || type == "message.interim" || (frameSegment != nil && frameSegment != segment) {
            deltas = ""
            segment = frameSegment
            missingDeltas = false
        }
        if type == "message.delta", let text = payload["text"].text, deltas.utf8.count <= 128 * 1024 {
            if let offset = payload["offset"].int, offset < deltas.utf16.count { return true }
            if let offset = payload["offset"].int, offset != deltas.utf16.count {
                missingDeltas = true
            } else if text.utf8.count + deltas.utf8.count <= 128 * 1024 {
                deltas += text
            } else {
                missingDeltas = true
            }
        }
        if type == "error" { finish(outcome(.failed)) }
        if type == "message.complete" {
            let status = payload["status"].text
            guard (status == "complete" || (status == nil && !conversation.usesSessionAuthority)),
                  payload["error"] == .null, payload["partial"].flag != true else {
                finish(outcome(.failed))
                return true
            }
            let final = payload["text"].text
            let useDeltas = (payload["response_reused"].flag == true && (final ?? "").isEmpty)
                || (final == nil && !conversation.usesSessionAuthority)
            if useDeltas && (missingDeltas || missedEarlyDelta) {
                finish(outcome(.deliveryUnknown))
                return true
            }
            let reply = useDeltas ? deltas : (final ?? "")
            if reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                finish(outcome(.noText))
            } else if reply.utf8.count > 128 * 1024 {
                finish(outcome(.replyTooLarge))
            } else {
                var result = outcome(.completed)
                result.reply = reply
                finish(result)
            }
        }
        return true
    }

    static func hasInput(_ snapshot: JSON) -> Bool {
        let prompts = snapshot["prompts"].list ?? []
        let requests = snapshot["open_requests"].list ?? snapshot["info"]["open_requests"].list ?? []
        return !prompts.isEmpty || !requests.isEmpty || snapshot["pending_connection"] != .null
    }

    private func expire() {
        finish(outcome(receipt != nil ? .timedOut : .deliveryUnknown))
    }

    private func disconnected() {
        finish(sent ? outcome(.deliveryUnknown) : outcome(.unreachable, route: .settings))
    }

    private func finish(_ outcome: HermesAskOutcome) {
        completion?.yield(outcome)
        completion?.finish()
        completion = nil
    }

    private func outcome(_ status: HermesAskStatus, _ message: LocalizedStringResource? = nil, route: HermesHandoff? = nil) -> HermesAskOutcome {
        let chat = scope.flatMap { scope in
            conversation.storedKey.map { HermesHandoff.chat(scope: scope, key: $0, status: status,
                                                           admission: receipt?["admission_id"].text) }
        }
        return HermesAskOutcome(status, message: message, route: route ?? chat ?? .chats)
    }

    static func connectionFailure(_ error: Error) -> HermesAskOutcome {
        switch error {
        case HermesError.notConfigured:
            HermesAskOutcome(.notConfigured, route: .settings)
        case HermesError.wrongPassword, HermesError.browserOnly, HermesError.http(401, _), HermesError.http(403, _):
            HermesAskOutcome(.signInRequired, route: .settings)
        case let error as URLError where error.code == .notConnectedToInternet:
            HermesAskOutcome(.offline)
        default:
            HermesAskOutcome(.unreachable, route: .settings)
        }
    }
}
