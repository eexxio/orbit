import Foundation

struct HermesSession: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let title: String
    let lastActive: Double?
}

/// One transcript item. `role` is "user" or "assistant" for chat text, "reasoning" for the
/// agent's thinking, and "tool" for a tool call (described by `tool`).
struct HermesMessage: Codable, Hashable, Sendable {
    var role: String
    var text: String
    /// Optional so conversations cached before tool calls were shown still decode.
    var tool: HermesToolCall? = nil
    /// How fast this reply streamed. Only the device saw that, so it lives in the cache alone;
    /// optional so older cached conversations still decode.
    var rate: TokenRate? = nil

    var isUser: Bool { role == "user" }
}

struct HermesToolCall: Codable, Hashable, Sendable {
    var id: String
    var name: String
    /// A short argument preview, such as the command or path.
    var context: String
    /// The server's one-line result summary, when it gives one.
    var summary: String?
    var isDone: Bool
}

extension HermesToolCall {
    /// A stored OpenAI-style call, `{id, function: {name, arguments}}`. The arguments are a JSON
    /// string; stored transcripts carry no server-made preview, so pick one telling string from them.
    init?(stored call: JSON) {
        let function = call["function"]
        guard let name = function["name"].text ?? call["name"].text, !name.isEmpty else { return nil }
        var arguments = function["arguments"]
        if let raw = arguments.text { arguments = JSON.decode(Data(raw.utf8)) ?? .null }
        self.init(id: call["id"].text ?? "", name: name, context: Self.preview(of: arguments),
                  summary: nil, isDone: true)
    }

    private static func preview(of arguments: JSON) -> String {
        let preferred = ["command", "cmd", "path", "file_path", "url", "query", "pattern", "name"]
        var value = preferred.lazy.compactMap { arguments[$0].text }.first { !$0.isEmpty }
        if value == nil, case .object(let fields) = arguments {
            value = fields.keys.sorted().lazy.compactMap { fields[$0]?.text }.first { !$0.isEmpty }
        }
        let line = (value ?? "").split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return line.count > 80 ? String(line.prefix(79)) + "…" : line
    }
}
