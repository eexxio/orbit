import SwiftUI

struct SlashResult: Identifiable {
    let id = UUID()
    let title: String
    let output: String
    var warning: String? = nil
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
                        Label(warning, systemImage: "exclamationmark.circle").foregroundStyle(.secondary)
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
    }
}
