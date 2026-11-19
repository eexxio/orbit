import Foundation

nonisolated struct MarkdownTranscript: Sendable {
    enum ReplyNote: String, Sendable {
        case inProgress = "A reply was still in progress at the time of export."
        case interrupted = "The latest reply was interrupted."
        case failed = "The latest reply failed."
    }

    private let title: String
    private let messages: [HermesMessage]
    private let note: ReplyNote?

    init(title: String, messages: [HermesMessage], note: ReplyNote?) {
        let heading = title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        self.title = heading.isEmpty ? "Orbit chat" : heading
        self.messages = messages
        self.note = note
    }

    static func includes(_ message: HermesMessage) -> Bool {
        guard case nil = message.tool, message.role == "user" || message.role == "assistant" else { return false }
        return message.text.contains { !$0.isWhitespace }
    }

    private var filename: String {
        let safe = String(title.map { character in
            character.isLetter || character.isNumber || character == "-" || character == "_" ? character : " "
        })
        let stem = safe.split(separator: " ").joined(separator: " ")
        var capped = ""
        var bytes = 0
        for character in stem {
            bytes += String(character).utf8.count
            if bytes > 80 { break }
            capped.append(character)
        }
        capped = capped.trimmingCharacters(in: .whitespaces)
        return (capped.isEmpty ? "Orbit chat" : capped) + ".md"
    }

    private var markdown: String {
        let markers = #"#*[!<~_&`\"#
        let leading = title.prefix { markers.contains($0) }
        let heading = leading.map { "\\" + String($0) }.joined() + title.dropFirst(leading.count)
        var sections = [
            "# \(heading)",
            "This export includes the messages available in orbit at the time of export.",
        ]
        if let note { sections.append("*\(note.rawValue)*") }

        var previousWasAssistant = false
        for message in messages {
            if message.role == "user" {
                sections.append("## You")
            } else if !previousWasAssistant {
                sections.append("## Assistant")
            }
            previousWasAssistant = message.role == "assistant"
            let text = message.text.replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
            sections.append(text)
        }
        return sections.joined(separator: "\n\n") + "\n"
    }

    private static var stagingRoot: URL {
        FileManager.default.temporaryDirectory.appending(component: "MarkdownExports", directoryHint: .isDirectory)
    }

    func stage() throws -> URL {
        let folder = Self.stagingRoot.appending(component: UUID().uuidString, directoryHint: .isDirectory)
        let file = folder.appending(component: filename, directoryHint: .notDirectory)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(markdown.utf8).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return file
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    static func removeStagedFile(_ file: URL) {
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }

    static func pruneStaging() {
        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
        let files = try? FileManager.default.contentsOfDirectory(
            at: stagingRoot, includingPropertiesForKeys: [.contentModificationDateKey]
        )
        for folder in files ?? [] {
            guard let modified = try? folder.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  modified < cutoff else { continue }
            try? FileManager.default.removeItem(at: folder)
        }
    }
}
