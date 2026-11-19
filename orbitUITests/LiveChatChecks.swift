import Foundation

@MainActor
final class HermesClient {
    static let shared = HermesClient()
    var cached: [HermesMessage]?
    var pending: CheckedContinuation<[HermesMessage], Error>?
    func cachedMessages(for key: String) -> [HermesMessage]? { cached }
    func messages(for key: String) async throws -> [HermesMessage] {
        try await withCheckedThrowingContinuation { pending = $0 }
    }
    func keepLive(_ chat: LiveChat, as key: String) {}
    func releaseLive(_ chat: LiveChat, key: String) {}
    func cacheMessages(_ messages: [HermesMessage], for key: String) {}
    func refreshSessions() async {}
}

@MainActor
final class HermesConversation {
    let storedKey: String?
    var onDelta: ((String) -> Void)?
    var onComplete: ((String?, Int?, String?) -> Void)?
    var onError: ((String) -> Void)?
    var onDisconnect: (() -> Void)?
    var onInterim: ((String, Bool) -> Void)?
    var onReasoning: ((String, Bool) -> Void)?
    var onToolStart: ((HermesToolCall) -> Void)?
    var onToolComplete: ((String, String?) -> Void)?
    init(storedKey: String?) { self.storedKey = storedKey }
    func close() {}
    func interrupt(timeout: Duration) async -> Bool { true }
    func send(_ text: String) async throws { onComplete?("New reply", nil, nil) }
}

@main
struct Checks {
    @MainActor
    static func main() async {
        let client = HermesClient.shared
        let old = [HermesMessage(role: "user", text: "Old prompt"), HermesMessage(role: "assistant", text: "Old reply")]
        for cached in [nil, Optional(old)] {
            client.cached = cached
            let chat = LiveChat(key: "stored")
            let loading = Task { await chat.loadHistory() }
            while client.pending == nil { await Task.yield() }
            client.pending!.resume(throwing: HermesError.socketClosed)
            client.pending = nil
            await loading.value
            precondition(chat.isIdle)
            chat.send("New prompt")
            while chat.isGenerating { await Task.yield() }
            precondition(chat.isIdle && chat.messages.last?.text == "New reply")
            chat.regenerate()
            while chat.isGenerating { await Task.yield() }
            precondition(chat.messages.filter { $0.text == "New prompt" }.count == 2)
        }
        print("PASS: failed history loads with and without cache allow new sends and append-only regeneration")
        for fails in [false, true] {
            client.cached = nil
            let chat = LiveChat(key: "stored")
            let loading = Task { await chat.loadHistory() }
            while client.pending == nil { await Task.yield() }
            chat.shutDown()
            if fails { client.pending!.resume(throwing: HermesError.socketClosed) }
            else { client.pending!.resume(returning: old) }
            client.pending = nil
            await loading.value
            precondition(chat.messages.isEmpty && !chat.isIdle && !chat.isLoadingHistory)
            chat.send("Blocked")
            chat.regenerate()
            precondition(chat.messages.isEmpty)
        }
        print("PASS: history success and failure after shutdown cannot revive actions or change the transcript")
        client.cached = nil
        let chat = LiveChat(key: "stored")
        let loading = Task { await chat.loadHistory() }
        while client.pending == nil { await Task.yield() }
        client.pending!.resume(returning: old)
        client.pending = nil
        await loading.value
        precondition(chat.isIdle && chat.messages.map(\.item) == old)
        print("PASS: ordinary history completion still loads the transcript")
    }
}
