import SwiftUI

struct PromptSnippetsView: View {
    private var store: PromptSnippetStore { HermesClient.shared.snippetStore }
    @State private var editing: PromptSnippet?
    @State private var deleting: PromptSnippet?
    @State private var editMode = EditMode.inactive

    var body: some View {
        List {
            ForEach(Array(store.snippets.enumerated()), id: \.element.id) { index, snippet in
                HStack {
                    if editMode.isEditing {
                        Button { deleting = snippet } label: { Image(systemName: "minus.circle.fill") }
                            .foregroundStyle(.red).buttonStyle(.borderless)
                            .accessibilityLabel("Delete \(snippet.name)")
                            .accessibilityIdentifier("snippets.remove.\(snippet.name)")
                    }
                    Button { editing = snippet } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(snippet.name).foregroundStyle(.primary)
                            Text(snippet.preview).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .accessibilityIdentifier("snippets.row.\(snippet.name)")
                    .accessibilityAction(named: "Move up") {
                        if index > 0 { store.move(from: IndexSet(integer: index), to: index - 1) }
                    }
                    .accessibilityAction(named: "Move down") {
                        if index + 1 < store.snippets.count { store.move(from: IndexSet(integer: index), to: index + 2) }
                    }
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button("Delete", role: .destructive) { deleting = snippet }
                        .accessibilityIdentifier("snippets.delete.\(snippet.name)")
                }
            }
            .onMove { store.move(from: $0, to: $1) }
        }
        .overlay {
            if store.snippets.isEmpty {
                ContentUnavailableView {
                    Label("No saved snippets", systemImage: "text.alignleft")
                } description: { Text("Save prompts you use often.") } actions: {
                    Button("New snippet") { add() }.accessibilityIdentifier("snippets.empty.add")
                }
            }
        }
        .navigationTitle("Prompt snippets")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { add() } label: { Image(systemName: "plus") }
                    .accessibilityLabel("New snippet").accessibilityIdentifier("snippets.add")
            }
            ToolbarItem(placement: .topBarLeading) { EditButton().accessibilityIdentifier("snippets.edit") }
        }
        .sheet(item: $editing) { SnippetEditor(snippet: $0) }
        .confirmationDialog(deleting.map { "Delete “\($0.name)”?" } ?? "Delete snippet?", isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }
        ), titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let deleting { store.delete(deleting) }
                deleting = nil
            }.accessibilityIdentifier("snippets.confirmDelete")
            Button("Cancel", role: .cancel) { deleting = nil }
        }
        .tint(.primary)
        .environment(\.editMode, $editMode)
    }

    private func add() { editing = PromptSnippet(name: "", body: "") }
}

struct SnippetEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var snippet: PromptSnippet
    @State private var original: PromptSnippet?
    @State private var confirmDiscard = false
    private var store: PromptSnippetStore { HermesClient.shared.snippetStore }
    private var isNew: Bool { !store.snippets.contains { $0.id == snippet.id } }
    private var dirty: Bool { original.map { $0.name != snippet.name || $0.body != snippet.body } ?? false }
    private var isValid: Bool {
        !snippet.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !snippet.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !store.hasDuplicate(snippet)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Name", text: $snippet.name).accessibilityIdentifier("snippet.title")
                    if store.hasDuplicate(snippet) {
                        Text("A snippet with this name already exists")
                            .font(.footnote).foregroundStyle(.red).accessibilityIdentifier("snippet.duplicate")
                    }
                }
                Section {
                    TextEditor(text: $snippet.body).frame(minHeight: 180)
                        .accessibilityLabel("Prompt").accessibilityIdentifier("snippet.body")
                } header: { Text("Prompt") } footer: {
                    Text("Saved on this device. Don’t include passwords or access tokens.")
                }
            }
            .navigationTitle(isNew ? "New snippet" : "Edit snippet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { if dirty { confirmDiscard = true } else { dismiss() } }
                        .accessibilityIdentifier("snippet.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { store.save(snippet); dismiss() }
                        .disabled(!isValid).accessibilityIdentifier("snippet.save")
                }
            }
        }
        .tint(.primary)
        .onAppear { if original == nil { original = snippet } }
        .background(DiscardDismissGuard(isDisabled: dirty) { confirmDiscard = true })
        .confirmationDialog("Discard changes?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard changes", role: .destructive) { dismiss() }.accessibilityIdentifier("snippet.discard")
            Button("Keep editing", role: .cancel) {}.accessibilityIdentifier("snippet.keepEditing")
        }
    }
}

private struct DiscardDismissGuard: UIViewRepresentable {
    let isDisabled: Bool
    let attempted: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> UIView { UIView() }
    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.attempted = attempted
        DispatchQueue.main.async {
            guard let controller = view.parentController else { return }
            controller.isModalInPresentation = isDisabled
            controller.presentationController?.delegate = context.coordinator
        }
    }

    final class Coordinator: NSObject, UIAdaptivePresentationControllerDelegate {
        var attempted: (() -> Void)?
        func presentationControllerDidAttemptToDismiss(_ presentationController: UIPresentationController) { attempted?() }
    }
}

private extension UIView {
    var parentController: UIViewController? {
        var responder: UIResponder? = self
        while let next = responder?.next {
            if let controller = next as? UIViewController { return controller }
            responder = next
        }
        return nil
    }
}
