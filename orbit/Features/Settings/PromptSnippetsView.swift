import SwiftUI

struct PromptSnippetsView: View {
    private var client = HermesClient.shared
    @State private var editing: PromptSnippet?

    var body: some View {
        List {
            ForEach(client.snippets) { snippet in
                Button { editing = snippet } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(snippet.title).foregroundStyle(.primary)
                        Text(snippet.body).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .accessibilityIdentifier("snippets.row.\(snippet.title)")
            }
            .onDelete { client.deleteSnippets(at: $0) }
            .onMove { client.moveSnippets(from: $0, to: $1) }
        }
        .overlay {
            if client.snippets.isEmpty {
                ContentUnavailableView("No snippets yet", systemImage: "text.quote", description: Text("Save prompts to reuse them with / in any chat."))
            }
        }
        .navigationTitle("Prompt snippets")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { editing = PromptSnippet(title: "", body: "") } label: { Image(systemName: "plus") }
                    .accessibilityIdentifier("snippets.add")
            }
            ToolbarItem(placement: .topBarLeading) { EditButton().accessibilityIdentifier("snippets.edit") }
        }
        .sheet(item: $editing) { SnippetEditor(snippet: $0) }
    }
}

struct SnippetEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var snippet: PromptSnippet

    private var isValid: Bool {
        !snippet.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !snippet.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Title") {
                    TextField("Title", text: $snippet.title)
                        .accessibilityIdentifier("snippet.title")
                }
                Section("Prompt") {
                    TextEditor(text: $snippet.body)
                        .frame(minHeight: 180)
                        .accessibilityIdentifier("snippet.body")
                }
            }
            .navigationTitle("Prompt snippet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.accessibilityIdentifier("snippet.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        HermesClient.shared.saveSnippet(snippet)
                        dismiss()
                    }
                    .disabled(!isValid)
                    .accessibilityIdentifier("snippet.save")
                }
            }
        }
    }
}
