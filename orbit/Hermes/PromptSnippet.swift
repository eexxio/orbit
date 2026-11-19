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

    static func parse(_ reply: JSON) -> [HermesCommand]? {
        guard let pairs = reply["pairs"].list, !pairs.isEmpty else { return nil }
        var summaries: [String: String] = [:]
        var hasValidPair = false
        for row in pairs {
            guard let pair = row.list, pair.count == 2, let raw = pair[0].text,
                  let summary = pair[1].text else { continue }
            hasValidPair = true
            let token = raw.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
            let canonical = (reply["canon"][token].text ?? token)
                .trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
            let name = canonical == "ctx" ? "context" : canonical
            guard fallback.contains(where: { $0.name == name && !$0.isLocal }) else { continue }
            summaries[name] = summary
        }
        guard hasValidPair else { return nil }
        return fallback.filter { $0.isLocal || summaries[$0.name] != nil }.map {
            HermesCommand(name: $0.name, summary: summaries[$0.name] ?? $0.summary)
        }
    }
}

struct HermesCommandCatalog {
    var commands: [HermesCommand]
    var isFallback: Bool

    static let fallback = HermesCommandCatalog(commands: HermesCommand.fallback, isFallback: true)
}
