import Foundation

struct PromptSnippet: Identifiable, Codable {
    var id = UUID()
    var title: String
    var body: String
}

struct HermesCommand: Identifiable {
    var name: String
    var summary: String
    var id: String { name }

    static let fallback: [HermesCommand] = [
        .init(name: "help", summary: "Show available commands"),
        .init(name: "model", summary: "Choose a model"),
        .init(name: "compress", summary: "Compress conversation context"),
        .init(name: "usage", summary: "Show token usage"),
        .init(name: "skills", summary: "List available skills"),
        .init(name: "reset", summary: "Reset the conversation")
    ]

    static func parse(_ reply: JSON) -> [HermesCommand] {
        let rows = reply.list ?? reply["commands"].list ?? reply["catalog"].list ?? []
        var seen: Set<String> = []
        return rows.compactMap { row in
            guard let raw = row["name"].text ?? row.text else { return nil }
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !name.isEmpty, !name.contains(where: { $0.isWhitespace }), seen.insert(name).inserted else { return nil }
            return HermesCommand(name: name, summary: row["description"].text ?? "Run /\(name)")
        }
    }
}
