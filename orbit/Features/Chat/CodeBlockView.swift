import MarkdownUI
import SwiftUI
import UIKit

struct CodeBlockView: View {
    let configuration: CodeBlockConfiguration

    @State private var copied = false
    @State private var copyCount = 0
    @State private var resetTask: Task<Void, Never>?
    @ScaledMetric(relativeTo: .footnote) private var codeFontSize = 13

    private var language: String? {
        configuration.language?.split(whereSeparator: { $0.isWhitespace }).first.map {
            String($0.prefix(20))
        }
    }

    private var code: String {
        configuration.content.hasSuffix("\n")
            ? String(configuration.content.dropLast()) : configuration.content
    }

    var body: some View {
        VStack(spacing: 0) {
            if let language {
                HStack(spacing: 0) {
                    Text(language)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .accessibilityHidden(true)
                        .accessibilityIdentifier("chat.codeblock.language")
                    Spacer(minLength: 0)
                    if !code.isEmpty {
                        copyButton.padding(.vertical, -6)
                    }
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .frame(minHeight: 32)

                Divider()
            }

            ScrollView(.horizontal, showsIndicators: true) {
                configuration.label
                    .font(.system(.footnote, design: .monospaced))
                    .markdownTextStyle {
                        FontFamilyVariant(.monospaced)
                        FontSize(codeFontSize)
                    }
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .environment(\.layoutDirection, .leftToRight)
                    .padding(12)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(language ?? "") code block")
                    .accessibilityValue(code)
            }
            .padding(.trailing, language == nil && !code.isEmpty ? 44 : 0)
        }
        .overlay(alignment: .topTrailing) {
            if language == nil && !code.isEmpty {
                copyButton
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .clipShape(.rect(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(.separator), lineWidth: 0.5)
                .allowsHitTesting(false)
        }
        .markdownMargin(top: 8, bottom: 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.codeblock")
        .onDisappear { resetTask?.cancel() }
    }

    private var copyButton: some View {
        Button(action: copy) {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .contentTransition(.symbolEffect(.replace))
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .accessibilityLabel(language.map { "Copy \($0) code" } ?? "Copy code")
        .accessibilityValue(copied ? "Copied" : "")
        .accessibilityIdentifier("chat.codeblock.copy")
        .sensoryFeedback(.success, trigger: copyCount)
    }

    private func copy() {
        UIPasteboard.general.string = code
        copied = true
        copyCount += 1
        AccessibilityNotification.Announcement("Copied").post()
        resetTask?.cancel()
        resetTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            copied = false
        }
    }
}
