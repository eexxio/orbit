import Foundation
import Observation

@Observable
final class PromptSnippetStore {
    private struct Library: Codable {
        var version = 1
        var snippets: [PromptSnippet]
    }

    private let key = "hermes.promptSnippets.v1"
    private(set) var snippets: [PromptSnippet] = []

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let library = try? JSONDecoder().decode(Library.self, from: data), library.version == 1 {
            snippets = library.snippets
        }
        #if DEBUG
        if let seed = ProcessInfo.processInfo.environment["HERMES_TEST_SNIPPETS"],
           let data = seed.data(using: .utf8),
           let seeded = try? JSONDecoder().decode([PromptSnippet].self, from: data) {
            snippets = seeded
        }
        #endif
    }

    static func folded(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
    }

    func hasDuplicate(_ snippet: PromptSnippet) -> Bool {
        snippets.contains { $0.id != snippet.id && Self.folded($0.name) == Self.folded(snippet.name) }
    }

    func save(_ snippet: PromptSnippet) {
        guard !Self.folded(snippet.name).isEmpty,
              !snippet.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !hasDuplicate(snippet) else { return }
        var saved = snippet
        saved.name = snippet.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let index = snippets.firstIndex(where: { $0.id == snippet.id }) { snippets[index] = saved }
        else { snippets.append(saved) }
        persist()
    }

    func delete(_ snippet: PromptSnippet) {
        snippets.removeAll { $0.id == snippet.id }
        persist()
    }

    func move(from offsets: IndexSet, to destination: Int) {
        let moving = snippets.enumerated().filter { offsets.contains($0.offset) }.map(\.element)
        var remaining = snippets.enumerated().filter { !offsets.contains($0.offset) }.map(\.element)
        remaining.insert(contentsOf: moving, at: destination - offsets.filter { $0 < destination }.count)
        snippets = remaining
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(Library(snippets: snippets)) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
