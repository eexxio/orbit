import Foundation

enum StreamingMarkdown {
    nonisolated static func completingTableHeader(in text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        guard let last = lines.lastIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
            return text
        }
        var fence: (marker: Character, count: Int)?
        for line in lines[...last] {
            let leadingSpaces = line.prefix(while: { $0 == " " }).count
            guard leadingSpaces < 4 else { continue }
            let trimmed = line.dropFirst(leadingSpaces)
            guard let marker = trimmed.first, marker == "`" || marker == "~" else { continue }
            let count = trimmed.prefix(while: { $0 == marker }).count
            guard count >= 3 else { continue }
            if let current = fence {
                if marker == current.marker, count >= current.count,
                   trimmed.dropFirst(count).trimmingCharacters(in: .whitespaces).isEmpty {
                    fence = nil
                }
            } else {
                fence = (marker, count)
            }
        }
        let header = lines[last].trimmingCharacters(in: .whitespaces)
        guard fence == nil, header.hasPrefix("|"),
              !lines[last].hasPrefix("    "), !lines[last].hasPrefix("\t"),
              last == 0 || !lines[last - 1].trimmingCharacters(in: .whitespaces).hasPrefix("|") else {
            return text
        }
        var columns = 0
        var escaped = false
        var endsWithSeparator = false
        for character in header {
            endsWithSeparator = false
            if escaped {
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "|" {
                columns += 1
                endsWithSeparator = true
            }
        }
        if endsWithSeparator { columns -= 1 }
        guard columns > 0 else { return text }
        var completed = lines
        completed.insert("|" + String(repeating: " --- |", count: columns), at: last + 1)
        return completed.joined(separator: "\n")
    }
}
