import SwiftUI

struct ComposerTextView: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    let edited: (Bool) -> Void
    let selectionChanged: (Bool) -> Void
    let dismissSuggestions: () -> Void

    static func isTrigger(_ text: String) -> Bool {
        guard text.first == "/" else { return false }
        let allowed = CharacterSet.letters.union(.decimalDigits).union(.nonBaseCharacters)
            .union(CharacterSet(charactersIn: "-_"))
        return text.dropFirst().unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let view = SlashTextView()
        view.backgroundColor = .clear
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.delegate = context.coordinator
        view.accessibilityIdentifier = "chat.composer"
        view.accessibilityLabel = "Ask anything"
        view.autocorrectionType = .no
        view.escape = dismissSuggestions
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        if view.text != text {
            context.coordinator.updating = true
            view.text = text
            view.selectedRange = NSRange(location: (text as NSString).length, length: 0)
            context.coordinator.updating = false
        }
        if isFocused != view.isFirstResponder {
            DispatchQueue.main.async {
                if self.isFocused { view.becomeFirstResponder() }
                else { view.resignFirstResponder() }
            }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 200
        let height = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        let lineHeight = uiView.font?.lineHeight ?? 22
        return CGSize(width: width, height: min(max(lineHeight, height), lineHeight * 6))
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ComposerTextView
        var updating = false
        init(_ parent: ComposerTextView) { self.parent = parent }
        private func eligible(_ view: UITextView) -> Bool {
            view.markedTextRange == nil && view.selectedRange.length == 0
                && view.selectedRange.location == (view.text as NSString).length && ComposerTextView.isTrigger(view.text)
        }
        func textViewDidChange(_ view: UITextView) {
            guard !updating else { return }
            parent.text = view.text
            parent.edited(eligible(view))
        }
        func textViewDidChangeSelection(_ view: UITextView) {
            guard !updating else { return }
            parent.selectionChanged(eligible(view))
        }
        func textViewDidBeginEditing(_ view: UITextView) { parent.isFocused = true }
        func textViewDidEndEditing(_ view: UITextView) { parent.isFocused = false }
    }
}

private final class SlashTextView: UITextView {
    var escape: (() -> Void)?
    override var keyCommands: [UIKeyCommand]? {
        [UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(escapePressed))]
    }
    @objc private func escapePressed() { escape?() }
}
