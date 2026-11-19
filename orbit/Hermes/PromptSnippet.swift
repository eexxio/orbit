import Foundation

struct PromptSnippet: Identifiable, Codable {
    var id = UUID()
    var name: String
    var body: String

    var preview: String { body.split(whereSeparator: \.isNewline).map(String.init).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? "" }
}

struct HermesCommand: Identifiable {
    var name: String
    var summary: String
    var id: String { name }
    var aliases: [String] { name == "context" ? ["ctx"] : [] }
    var isLocal: Bool { name == "help" }

    static let fallback: [HermesCommand] = [
        .init(name: "help", summary: "See shortcuts available in Orbit"),
        .init(name: "status", summary: "Show chat details"),
        .init(name: "context", summary: "Show context usage"),
        .init(name: "usage", summary: "Show token usage")
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
