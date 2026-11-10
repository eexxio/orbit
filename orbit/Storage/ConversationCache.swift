import CryptoKit
import Foundation

/// On-device cache of the chat list and the most recent conversations, so they open instantly
/// and stay readable offline. Each server (address + username) gets its own folder under
/// Application Support, excluded from backups.
@MainActor
final class ConversationCache {
    /// How many conversations stay on device. The most recently active ones are prefetched.
    static let limit = 25

    private struct Entry: Codable {
        var messages: [HermesMessage]
        /// The session's `last_active` when these messages were read; a newer one means stale.
        var lastActive: Double?
        var touched: Date
    }

    private struct Index: Codable {
        var sessions: [HermesSession] = []
        /// Conversation key → metadata, without the messages.
        var conversations: [String: Stamp] = [:]
    }

    private struct Stamp: Codable {
        var lastActive: Double?
        var touched: Date
    }

    private let folder: URL
    private var index: Index

    init(address: String, username: String) {
        let identity = address.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) + "\n" + username
        let digest = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ConversationCache", isDirectory: true)
        folder = base.appendingPathComponent(String(digest.prefix(24)), isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var root = base
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? root.setResourceValues(values)
        index = (try? Data(contentsOf: folder.appendingPathComponent("index.json")))
            .flatMap { try? JSONDecoder().decode(Index.self, from: $0) } ?? Index()
    }

    // MARK: Chat list

    var sessions: [HermesSession] { index.sessions }

    func store(sessions: [HermesSession]) {
        index.sessions = sessions
        saveIndex()
    }

    // MARK: Conversations

    func messages(for key: String) -> [HermesMessage]? {
        guard index.conversations[key] != nil,
              let data = try? Data(contentsOf: file(for: key)),
              let entry = try? JSONDecoder().decode(Entry.self, from: data) else { return nil }
        return entry.messages
    }

    /// Whether `session` has no cached copy, or one older than its latest activity.
    func isStale(_ session: HermesSession) -> Bool {
        guard let stamp = index.conversations[session.id] else { return true }
        guard let live = session.lastActive else { return false }
        return (stamp.lastActive ?? 0) < live
    }

    func store(_ messages: [HermesMessage], for key: String, lastActive: Double?) {
        let now = Date()
        let entry = Entry(messages: messages, lastActive: lastActive ?? index.conversations[key]?.lastActive, touched: now)
        index.conversations[key] = Stamp(lastActive: entry.lastActive, touched: now)
        let url = file(for: key)
        if let data = try? JSONEncoder().encode(entry) {
            Self.write(data, to: url)
        }
        evict()
        saveIndex()
    }

    func clear() {
        index = Index()
        let folder = self.folder
        Self.io.async {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
    }

    // MARK: Private

    /// Keeps the conversations of the newest sessions in the list, then the most recently opened.
    private func evict() {
        guard index.conversations.count > Self.limit else { return }
        let recent = Array(index.sessions.prefix(Self.limit).map(\.id))
        let keep = Set(recent)
        let ranked = index.conversations.keys.sorted { a, b in
            let ka = keep.contains(a), kb = keep.contains(b)
            if ka != kb { return ka }
            return (index.conversations[a]?.touched ?? .distantPast) > (index.conversations[b]?.touched ?? .distantPast)
        }
        for key in ranked.dropFirst(Self.limit) {
            index.conversations[key] = nil
            try? FileManager.default.removeItem(at: file(for: key))
        }
    }

    private func saveIndex() {
        guard let data = try? JSONEncoder().encode(index) else { return }
        let url = folder.appendingPathComponent("index.json")
        Self.write(data, to: url)
    }

    /// One serial queue, so writes of the same file land in order, off the main thread.
    nonisolated private static let io = DispatchQueue(label: "orbit.conversation-cache", qos: .utility)

    nonisolated private static func write(_ data: Data, to url: URL) {
        io.async { try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) }
    }

    private func file(for key: String) -> URL {
        let safe = key.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? key
        return folder.appendingPathComponent(safe + ".json")
    }
}
