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
    @ScaledMetric(relativeTo: .footnote) private var iconSize: CGFloat = 16

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if tool.isDone {
                    Image(systemName: "checkmark.circle")
                } else if isLive {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "exclamationmark.circle")
                }
            }
            .frame(width: iconSize, height: iconSize)
            .accessibilityHidden(true)

            Text(tool.name)
                .font(.footnote.monospaced().weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .layoutPriority(2)

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
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(uiColor: .secondarySystemBackground), in: .rect(cornerRadius: 10))
        .accessibilityElement(children: .combine)
        .accessibilityValue(tool.isDone ? "Completed" : isLive ? "Running" : "Tool result not received")
    }
}

struct ReplyActivityRow: View {
    let isStreaming: Bool
    @ScaledMetric(relativeTo: .subheadline) private var iconSize: CGFloat = 20
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 6) {
            ZStack {
                if isStreaming {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "brain").symbolEffect(.pulse, isActive: !reduceMotion)
                }
            }
            .frame(width: iconSize, height: iconSize)
            .accessibilityHidden(true)

            Text(isStreaming ? "Replying…" : "Thinking…")
                .contentTransition(.opacity)
                .accessibilityIdentifier(isStreaming ? "chat.reply.streaming" : "chat.reply.waiting")
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: isStreaming)
    }
}

struct JumpToLatestButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.down")
                .font(.body.weight(.semibold))
                .frame(width: 44, height: 44)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel("Jump to latest")
    }
}
