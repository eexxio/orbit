import LinkPresentation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ChatExportButton: View {
    let chat: LiveChat

    @AppStorage(AppearanceKey.accent) private var accent = Accent.mono
    @State private var isPreparing = false
    @State private var isSharing = false
    @State private var showError = false

    var body: some View {
        ShareToolbarControl(tint: accent == .mono ? nil : UIColor(accent.color),
                            isPreparing: isPreparing, isSharing: isSharing, action: export)
            .frame(width: 44, height: 44)
            .alert("Couldn’t export chat", isPresented: $showError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("orbit couldn’t prepare the Markdown file. Try again.")
            }
    }

    private func export(from anchor: UIButton) {
        guard !isPreparing, !isSharing else { return }
        let messages = chat.transcript.filter(MarkdownTranscript.includes)
        guard !messages.isEmpty else { return }
        let title = HermesClient.shared.sessions.first { $0.id == chat.key }?.title ?? "Orbit chat"
        let snapshot = MarkdownTranscript(title: title, messages: messages, note: chat.replyState.exportNote)
        isPreparing = true

        Task {
            do {
                let file = try await Task.detached(priority: .userInitiated) { try snapshot.stage() }.value
                isSharing = share(file, from: anchor) {
                    isSharing = false
                }
                if !isSharing {
                    Task.detached(priority: .utility) { MarkdownTranscript.removeStagedFile(file) }
                    showError = true
                }
            } catch {
                showError = true
            }
            isPreparing = false
        }
    }

    private func share(_ file: URL, from anchor: UIButton, onDismiss: @escaping @MainActor () -> Void) -> Bool {
        guard let root = anchor.window?.rootViewController else { return false }
        var host = root
        while let presented = host.presentedViewController { host = presented }
        guard !host.isBeingDismissed else { return false }

        let provider = NSItemProvider()
        provider.suggestedName = file.lastPathComponent
        provider.registerFileRepresentation(for: .markdown) { completion in
            completion(file, false, nil)
            return nil
        }
        let metadata = LPLinkMetadata()
        metadata.title = file.lastPathComponent
        if let icon = UIImage(systemName: "doc.text") {
            metadata.iconProvider = NSItemProvider(object: icon)
        }
        let configuration = UIActivityItemsConfiguration(itemProviders: [provider])
        configuration.perItemMetadataProvider = { _, key in
            key == .linkPresentationMetadata ? metadata : nil
        }
        let controller = UIActivityViewController(activityItemsConfiguration: configuration)
        controller.popoverPresentationController?.sourceView = anchor
        controller.popoverPresentationController?.sourceRect = anchor.bounds
        controller.completionWithItemsHandler = { [weak anchor] _, _, _, _ in
            Task.detached(priority: .utility) { MarkdownTranscript.removeStagedFile(file) }
            Task { @MainActor in
                onDismiss()
                if UIAccessibility.isVoiceOverRunning, let anchor, anchor.window != nil {
                    UIAccessibility.post(notification: .layoutChanged, argument: anchor)
                }
            }
        }
        host.present(controller, animated: true)
        return true
    }
}

private struct ShareToolbarControl: UIViewRepresentable {
    private static let label = "Export Chat as Markdown"

    let tint: UIColor?
    let isPreparing: Bool
    let isSharing: Bool
    let action: (UIButton) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(configuration: .plain())
        button.accessibilityIdentifier = "chat.export.markdown"
        button.isPointerInteractionEnabled = true
        button.addInteraction(UIToolTipInteraction(defaultToolTip: Self.label))
        button.addTarget(context.coordinator, action: #selector(Coordinator.activate(_:)), for: .primaryActionTriggered)
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {
        context.coordinator.action = action
        var configuration = UIButton.Configuration.plain()
        let symbol = UIImage(systemName: "square.and.arrow.up")
        configuration.image = tint.map { symbol?.withTintColor($0, renderingMode: .alwaysOriginal) } ?? symbol
        configuration.showsActivityIndicator = isPreparing
        configuration.contentInsets = .zero
        configuration.baseForegroundColor = tint ?? .label
        button.configuration = configuration
        button.isEnabled = !isPreparing && !isSharing
        button.accessibilityLabel = isPreparing ? "Preparing Markdown export" : Self.label
    }

    final class Coordinator: NSObject {
        var action: ((UIButton) -> Void)?

        @objc func activate(_ button: UIButton) {
            action?(button)
        }
    }
}
