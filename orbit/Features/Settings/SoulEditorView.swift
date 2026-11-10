import SwiftUI

/// Edits the active profile's SOUL.md, the file Hermes reads as the agent's persona.
struct SoulEditorView: View {

    private let client = HermesClient.shared
    @State private var text = ""
    @State private var saved: String?
    @State private var isSaving = false
    @State private var error: String?

    private var isLoaded: Bool { saved != nil }
    private var hasChanges: Bool { isLoaded && text != saved }

    var body: some View {

        Group {
            if isLoaded {
                TextEditor(text: $text)
                    .font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .contentMargins(.horizontal, 16, for: .scrollContent)
            } else if let error {
                ContentUnavailableView {
                    Label("Couldn't Load SOUL.md", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try Again") { Task { await load() } }
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle("SOUL.md")
        .navigationBarTitleDisplayMode(.inline)
        // Unsaved edits can't be lost by accident: Back becomes Revert and the sheet won't swipe away.
        .navigationBarBackButtonHidden(hasChanges)
        .interactiveDismissDisabled(hasChanges)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if isSaving {
                    ProgressView()
                } else {
                    Button("Save") { Task { await save() } }
                        .disabled(!hasChanges)
                }
            }
            if hasChanges {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Revert", role: .destructive) { text = saved ?? "" }
                }
            }
        }
        .alert("Couldn't Save", isPresented: .constant(isLoaded && error != nil)) {
            Button("OK") { error = nil }
        } message: {
            Text(error ?? "")
        }
        .task { if !isLoaded { await load() } }
    }

    private func load() async {
        error = nil
        do {
            let content = try await client.soul()
            text = content
            saved = content
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            try await client.saveSoul(text)
            saved = text
        } catch {
            self.error = error.localizedDescription
        }
    }
}
