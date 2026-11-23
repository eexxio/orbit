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
        let trailing = lines[last].trimmingCharacters(in: .whitespaces)
        let pendingDelimiter = last > 0 && !trailing.isEmpty
            && trailing.allSatisfy { "|-: ".contains($0) }
            && lines[last - 1].trimmingCharacters(in: .whitespaces).hasPrefix("|")
        let headerIndex = pendingDelimiter ? last - 1 : last
        let header = lines[headerIndex].trimmingCharacters(in: .whitespaces)
        guard fence == nil, header.hasPrefix("|"),
              !lines[headerIndex].hasPrefix("    "), !lines[headerIndex].hasPrefix("\t"),
              headerIndex == 0 || !lines[headerIndex - 1].trimmingCharacters(in: .whitespaces).hasPrefix("|") else {
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
        let separator = "|" + String(repeating: " --- |", count: columns)
        if pendingDelimiter {
            let cells = trailing.trimmingCharacters(in: CharacterSet(charactersIn: "|"))
                .components(separatedBy: "|")
            if cells.count == columns && cells.allSatisfy({
                $0.trimmingCharacters(in: .whitespaces).range(of: "^:?-+:?$", options: .regularExpression) != nil
            }) { return text }
            completed[last] = separator
        } else {
            completed.insert(separator, at: last + 1)
        }
        return completed.joined(separator: "\n")
    }
}
