import SwiftUI

struct SlashResult: Identifiable {
    let id = UUID()
    let title: String
    let output: String
    var warning: String? = nil

    nonisolated static func plain(_ text: String) -> String {
        let stripped = text.replacingOccurrences(of: "\u{001B}\\[[0-?]*[ -/]*[@-~]|\u{001B}\\][^\u{0007}\u{001B}]*(?:\u{0007}|\u{001B}\\\\)", with: "", options: .regularExpression)
        return String(stripped.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) || $0 == "\n" || $0 == "\t"
        })
    }

    init(title: String, output: String, warning: String? = nil) {
        self.title = title
        let plain = Self.plain(output).trimmingCharacters(in: .whitespacesAndNewlines)
        self.output = plain.isEmpty || plain == "(no output)" ? "No information returned" : plain
        self.warning = warning.map(Self.plain)
    }
}

struct SlashResultView: View {
    let result: SlashResult
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(result.output).textSelection(.enabled).accessibilityIdentifier("slash.result.output")
                    if let warning = result.warning, !warning.isEmpty {
                        Label(warning, systemImage: "info.circle").foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding()
            }
            .navigationTitle(result.title).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.accessibilityIdentifier("slash.result.done")
                }
            }
        }
        .tint(.primary)
        .presentationDetents([.medium, .large])
    }
}
