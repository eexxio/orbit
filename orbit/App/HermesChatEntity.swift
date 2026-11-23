import AppIntents
import SwiftUI

enum HermesChatDestination: String, AppEnum {
    case newChat, existingChat

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Destination"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .newChat: DisplayRepresentation(title: "New Chat", image: .init(systemName: "square.and.pencil")),
        .existingChat: DisplayRepresentation(title: "Existing Chat", image: .init(systemName: "bubble.left.and.bubble.right"))
    ]
}

struct HermesChatEntity: AppEntity {
    let id: String
    let title: String
    var subtitle: String?

    var scope: String { String(id.split(separator: "|", maxSplits: 1).first ?? "") }
    var key: String { String(id.split(separator: "|", maxSplits: 1).dropFirst().first ?? "") }

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Hermes Chat"
    static let defaultQuery = HermesChatQuery()

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: subtitle.map { "\($0)" })
    }
}

struct HermesChatQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [HermesChatEntity] {
        guard UIApplication.shared.isProtectedDataAvailable else { return [] }
        let client = HermesClient.shared
        let known = entitiesInMemory() ?? []
        return identifiers.compactMap { id in
            if let exact = known.first(where: { $0.id == id }) { return exact }
            let saved = HermesChatEntity(id: id, title: String(localized: "Saved Hermes chat"))
            guard client.isConfigured, saved.scope.hasPrefix(client.shortcutAccount + ":"),
                  !saved.key.isEmpty else { return nil }
            return saved
        }
    }

    @MainActor
    func suggestedEntities() async throws -> [HermesChatEntity] { entitiesInMemory() ?? [] }

    @MainActor
    func entities(matching string: String) async throws -> [HermesChatEntity] {
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        let matches = (entitiesInMemory() ?? []).filter { $0.title.range(of: string, options: options) != nil }
        return matches.filter { $0.title.compare(string, options: options) == .orderedSame }
            + matches.filter { $0.title.compare(string, options: options) != .orderedSame }
    }

    @MainActor
    private func entitiesInMemory() -> [HermesChatEntity]? {
        let client = HermesClient.shared
        guard UIApplication.shared.isProtectedDataAvailable, client.isConfigured,
              let list = client.shortcutSessions, list.scope == client.shortcutScope,
              client.hasValidatedShortcutScope else { return nil }
        return Self.entities(list.chats, scope: list.scope)
    }

    @MainActor
    static func choices() async throws -> [HermesChatEntity] {
        if let ready = Self().entitiesInMemory() { return ready }
        let (results, continuation) = AsyncThrowingStream<[HermesChatEntity], Error>.makeStream()
        let read = Task {
            do {
                let client = HermesClient.shared
                let chats = try await client.refreshShortcutSessions()
                continuation.yield(entities(chats, scope: client.shortcutScope))
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        let timer = Task {
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            continuation.finish(throwing: URLError(.timedOut))
        }
        defer { read.cancel(); timer.cancel() }
        var iterator = results.makeAsyncIterator()
        let value = try await iterator.next()
        try Task.checkCancellation()
        return value ?? []
    }

    private static func entities(_ chats: [HermesSession], scope: String) -> [HermesChatEntity] {
        let sorted = chats.sorted {
            let lhs = $0.lastActive ?? 0, rhs = $1.lastActive ?? 0
            return lhs == rhs ? $0.id < $1.id : lhs > rhs
        }
        let groups = Dictionary(grouping: sorted) { $0.title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) }
        var ordinals: [String: Int] = [:]
        return sorted.map { row in
            let siblings = groups[row.title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)] ?? []
            var subtitle: String?
            if siblings.count > 1 {
                let date = label(row.lastActive)
                if siblings.filter({ label($0.lastActive) == date }).count > 1 {
                    let ordinal = ordinals[siblings[0].id + date, default: 0] + 1
                    ordinals[siblings[0].id + date] = ordinal
                    subtitle = String(localized: "\(date) · \(ordinal)")
                } else {
                    subtitle = date
                }
            }
            return HermesChatEntity(id: scope + "|" + row.id, title: row.title, subtitle: subtitle)
        }
    }

    private static func label(_ seconds: Double?) -> String {
        seconds.map { Date(timeIntervalSince1970: $0).formatted(date: .abbreviated, time: .shortened) }
            ?? String(localized: "Unknown activity")
    }
}
