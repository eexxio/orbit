import SwiftUI

/// The agent's thinking, collapsed to one line by default so it doesn't crowd the reply.
struct ReasoningRow: View {
    let text: String
    /// True while this block still streams.
    let isLive: Bool
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.snappy(duration: 0.25)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "brain")
                    Text(isLive ? "Thinking…" : "Thought")
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")

            if isExpanded {
                Text(text)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.leading, 10)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(.quaternary).frame(width: 2)
                    }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One tool call as a compact line: its name, what it ran on, and its result summary.
struct ToolCallRow: View {
    let tool: HermesToolCall
    let isLive: Bool
    let openDetails: () -> Void
    @ScaledMetric(relativeTo: .footnote) private var iconWidth = 16.0

    private var status: ToolCallStatus { ToolCallStatus(tool: tool, isLive: isLive) }

    var body: some View {
        Button(action: openDetails) {
            HStack(spacing: 8) {
                status.icon
                    .frame(width: iconWidth)
                    .accessibilityHidden(true)

                Text(tool.name)
                    .font(.footnote.monospaced().weight(.medium))
                    .foregroundStyle(.primary)

                if !tool.context.isEmpty {
                    Text(tool.context)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                if let summary = tool.summary, !summary.isEmpty {
                    Text(summary)
                        .lineLimit(1)
                        .foregroundStyle(.tertiary)
                        .layoutPriority(1)
                }

                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .layoutPriority(3)
                    .accessibilityHidden(true)
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(uiColor: .secondarySystemBackground), in: .rect(cornerRadius: 10))
            .contentShape(.contextMenuPreview, .rect(cornerRadius: 10))
            .frame(minHeight: 44, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(ToolRowButtonStyle())
        .contextMenu {
            if let input = tool.arguments {
                Button("Copy Input", systemImage: "doc.on.doc") { copyToolPayload(input) }
            }
            if let output = tool.output {
                Button("Copy Output", systemImage: "doc.on.doc") { copyToolPayload(output) }
            }
            Button("Show Details", systemImage: "info.circle", action: openDetails)
        }
        .accessibilityValue(status.label)
        .accessibilityHint("Shows input and output")
        .accessibilityIdentifier("chat.tool.row")
    }

}

private struct ToolRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.6 : 1)
    }
}
