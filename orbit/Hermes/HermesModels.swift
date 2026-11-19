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
    var arguments: String?
    var output: String?
    var outputLimitedByServer: Bool?
    var diff: String?
    var duration: Double?
    var startedAt: Date?
    var calledAt: Date?
    var finishedAt: Date?
    var isError: Bool?
    var exitCode: Int?
    var errorMessage: String?
    var progress: Double?
    var progressMessage: String?

    var identity: String { id + ":" + name }

    var cachePreview: Self {
        Self(id: id, name: name, context: context, summary: summary, isDone: isDone, isError: isError)
    }
}

extension HermesToolCall {
    init?(live payload: JSON) {
        guard let id = payload["tool_id"].text, let name = payload["name"].text, !name.isEmpty else { return nil }
        let arguments = payload["args"]
        self.init(id: id, name: name, context: payload["context"].text ?? Self.preview(of: arguments),
                  summary: nil, isDone: false, arguments: arguments.rawToolText)
    }

    /// A stored OpenAI-style call, `{id, function: {name, arguments}}`. The arguments are a JSON
    /// string; stored transcripts carry no server-made preview, so pick one telling string from them.
    init?(stored call: JSON) {
        let function = call["function"]
        guard let name = function["name"].text ?? call["name"].text, !name.isEmpty else { return nil }
        let arguments = function["arguments"]
        let parsed = arguments.text.flatMap { JSON.decode(Data($0.utf8)) } ?? arguments
        self.init(id: call["id"].text ?? "", name: name, context: Self.preview(of: parsed),
                  summary: nil, isDone: false, arguments: arguments.rawToolText)
    }

    mutating func complete(with payload: JSON) {
        arguments = payload["args"].rawToolText ?? arguments
        summary = payload["summary"].text
        diff = payload["inline_diff"].text
        finishedAt = .now
        if let value = payload["duration_s"].double, value.isFinite, value >= 0 { duration = value }
        complete(result: payload["result"], isError: payload["is_error"].flag)
        if let encoded = payload["result"].text, let parsed = JSON.decode(Data(encoded.utf8)) {
            outputLimitedByServer = parsed["truncated"].flag
        }
    }

    mutating func updateProgress(_ payload: JSON) {
        let percent = payload["percent"].double.map { $0 / 100 }
        let fraction = payload["total"].double.flatMap { total in
            total > 0 ? payload["progress"].double.map { $0 / total } : nil
        }
        progress = (percent ?? fraction).flatMap { $0.isFinite ? min(max($0, 0), 1) : nil }
        progressMessage = payload["message"].text
    }

    mutating func complete(result: JSON, isError: Bool? = nil) {
        isDone = true
        output = result.rawToolText
        let parsed = result.text.flatMap { JSON.decode(Data($0.utf8)) } ?? result
        exitCode = parsed["exit_code"].int
        errorMessage = [parsed["user_summary"], parsed["error"]].compactMap(\.text)
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let status = parsed["status"].text?.lowercased()
        self.isError = isError ?? (parsed["success"].flag == false || parsed["ok"].flag == false
            || errorMessage != nil || status == "error" || status == "failed" || (exitCode ?? 0) != 0)
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
