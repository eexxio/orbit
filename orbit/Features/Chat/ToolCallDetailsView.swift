import SwiftUI

enum ToolCallStatus: Equatable {
    case running, completed, failed, unavailable

    init(tool: HermesToolCall, isLive: Bool) {
        if isLive { self = .running }
        else if tool.isError == true { self = .failed }
        else { self = tool.isDone ? .completed : .unavailable }
    }

    var label: String {
        switch self {
        case .running: "Running"
        case .completed: "Completed"
        case .failed: "Failed"
        case .unavailable: "Tool result not received"
        }
    }

    @ViewBuilder var icon: some View { icon(filled: false) }

    @ViewBuilder func icon(filled: Bool) -> some View {
        switch self {
        case .running: ProgressView().controlSize(filled ? .small : .mini)
        case .completed: Image(systemName: filled ? "checkmark.circle.fill" : "checkmark.circle")
        case .failed: Image(systemName: filled ? "xmark.circle.fill" : "xmark.circle").foregroundStyle(.red)
        case .unavailable: Image(systemName: "exclamationmark.circle")
        }
    }
}

struct ToolCallDetailsView: View {
    let chat: LiveChat
    let message: ChatMessage
    let wide: Bool
    let close: () -> Void
    @State private var lastMessage: ChatMessage?
    @State private var detent = PresentationDetent.medium
    @AppStorage("hermes.toolDetails.wrap") private var wrapsLines = true
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var connected: Bool { HermesClient.shared.state == .connected }

    var body: some View {
        let current = chat.messages.first { $0.id == message.id }
        let displayed = current ?? lastMessage ?? message
        NavigationStack {
            if let tool = displayed.tool {
                let status = ToolCallStatus(tool: tool, isLive: chat.liveToolIDs.contains(message.id))
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        header(tool, status: status)
                        timing(tool)
                        ToolPayloadBlock(title: "Input", id: "input", raw: tool.arguments,
                                         placeholder: inputPlaceholder(status, cached: displayed.isToolPreview),
                                         waiting: displayed.isToolPreview && chat.isRefreshingHistory,
                                         wide: wide, wraps: wrapsLines || dynamicTypeSize.isAccessibilitySize)
                        if let diff = tool.diff, !diff.isEmpty {
                            ToolPayloadBlock(title: "Changes", id: "diff", raw: diff, placeholder: "",
                                             wide: wide, wraps: wrapsLines || dynamicTypeSize.isAccessibilitySize)
                        }
                        if status == .failed, let error = tool.errorMessage {
                            Label {
                                Text(error).lineLimit(3)
                            } icon: {
                                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                            }
                            .font(.subheadline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(.red.opacity(0.10), in: .rect(cornerRadius: 12))
                        }
                        ToolPayloadBlock(title: "Output", id: "output", raw: tool.output,
                                         placeholder: outputPlaceholder(status, cached: displayed.isToolPreview),
                                         waiting: status == .running || (displayed.isToolPreview && chat.isRefreshingHistory),
                                         wide: wide, wraps: wrapsLines || dynamicTypeSize.isAccessibilitySize)
                        if tool.outputLimitedByServer == true {
                            Text("Hermes shortened this live output. Reload the chat to see the stored result.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        if status == .unavailable || displayed.isToolPreview || tool.outputLimitedByServer == true {
                            if connected && !chat.isGenerating && !chat.isRefreshingHistory {
                                Button("Reload Chat", systemImage: "arrow.clockwise") {
                                    Task { await chat.refreshHistory() }
                                }
                                .frame(minHeight: 44)
                                .accessibilityIdentifier("tool.details.reload")
                            }
                        }
                        if current == nil {
                            Text("This call is no longer in the chat.").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, wide ? 24 : 20)
                    .padding(.top, 8)
                    .padding(.bottom, 24)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: status)
                }
                .accessibilityIdentifier("tool.details")
                .navigationTitle(tool.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        Text(tool.name)
                            .font(.headline.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .accessibilityAddTraits(.isHeader)
                            .accessibilityIdentifier("tool.details.name")
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", action: close)
                            .keyboardShortcut(.cancelAction)
                            .accessibilityIdentifier("tool.details.done")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        actions(tool)
                    }
                }
                .sensoryFeedback(trigger: status) { old, new in
                    guard old == .running else { return nil }
                    switch new {
                    case .completed: return .success
                    case .failed: return .error
                    default: return nil
                    }
                }
            }
        }
        .presentationDetents(dynamicTypeSize.isAccessibilitySize ? [.large] : [.medium, .large], selection: $detent)
        .presentationDragIndicator(.visible)
        .presentationContentInteraction(.scrolls)
        .onAppear { detent = dynamicTypeSize.isAccessibilitySize ? .large : .medium }
        .onChange(of: current?.item, initial: true) { if let current { lastMessage = current } }
    }

    private func header(_ tool: HermesToolCall, status: ToolCallStatus) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                status.icon(filled: true).accessibilityHidden(true)
                Text(status == .unavailable ? "No result received" : status.label)
                    .foregroundStyle(.primary)
                if let exit = tool.exitCode, status == .failed {
                    Text("· exit \(exit)")
                }
                if let seconds = tool.duration {
                    Text("· \(durationText(seconds))")
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("tool.details.status")
            if status == .running, let progress = tool.progress {
                ProgressView(value: progress)
                    .tint(.primary)
                    .accessibilityLabel("Tool progress")
            }
            if status == .running, let progressMessage = tool.progressMessage, !progressMessage.isEmpty {
                Text(progressMessage).font(.caption).foregroundStyle(.secondary)
            }
            if !tool.context.isEmpty {
                Text(tool.context).font(.body.monospaced()).lineLimit(3).textSelection(.enabled)
            }
            if let summary = tool.summary, !summary.isEmpty {
                Text(summary).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func timing(_ tool: HermesToolCall) -> some View {
        let dates: [(String, Date?)] = [("Called", tool.calledAt), ("Finished", tool.finishedAt)]
        let values = dates.compactMap { label, date in date.map { (label, timeText($0)) } }
            + (tool.duration.map { [("Duration", durationText($0))] } ?? [])
        if !values.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ToolSectionTitle("Timing")
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    ForEach(values, id: \.0) { label, value in
                        if dynamicTypeSize.isAccessibilitySize {
                            VStack(alignment: .leading) {
                                Text(label).foregroundStyle(.secondary)
                                Text(value).monospacedDigit()
                            }
                            .accessibilityElement(children: .combine)
                        } else {
                            GridRow {
                                Text(label).foregroundStyle(.secondary)
                                Text(value).monospacedDigit()
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
                .font(.subheadline)
                .accessibilityIdentifier("tool.details.timing")
            }
        }
    }

    private func timeText(_ date: Date) -> String {
        date.formatted(Calendar.current.isDateInToday(date)
            ? .dateTime.hour().minute().second()
            : .dateTime.month(.abbreviated).day().hour().minute().second())
    }

    private func durationText(_ seconds: Double) -> String {
        if seconds < 60 {
            return "\(seconds.formatted(.number.precision(.fractionLength(seconds < 1 ? 2 : 1)))) s"
        }
        let duration = Duration.seconds(min(seconds, Double(Int32.max)))
        let units: Set<Duration.UnitsFormatStyle.Unit> = seconds < 3600 ? [.minutes, .seconds] : [.hours, .minutes]
        return duration.formatted(.units(allowed: units,
                                         width: .abbreviated, zeroValueUnits: .show(length: 2)))
    }

    private var notCached: String {
        "Not saved on this device. Connect to \(HermesClient.shared.baseURL?.host() ?? "Hermes") to load it."
    }

    private func inputPlaceholder(_ status: ToolCallStatus, cached: Bool) -> String {
        if cached { return notCached }
        return status == .running ? "Input not sent yet." : "No arguments"
    }

    private func outputPlaceholder(_ status: ToolCallStatus, cached: Bool) -> String {
        if cached { return notCached }
        switch status {
        case .running: return "Waiting for output…"
        case .unavailable:
            return chat.replyState == .stopped && chat.messages.lastIndex(where: \.isUser).map { index in
                chat.messages.dropFirst(index + 1).contains { $0.id == message.id }
            } == true
                ? "Stopped before the result came back."
                : "The server didn't send this call's result. It may still show after the chat reloads."
        default: return "No output"
        }
    }

    private func actions(_ tool: HermesToolCall) -> some View {
        Menu("Tool actions", systemImage: "ellipsis.circle") {
            if let input = tool.arguments {
                Button("Copy Input", systemImage: "doc.on.doc") { copyToolPayload(input) }
            }
            if let output = tool.output {
                Button("Copy Output", systemImage: "doc.on.doc") { copyToolPayload(output) }
                if output.utf8.count >= 64 * 1024 {
                    ShareLink(item: ToolOutputFile(name: "\(tool.name)-\(tool.id.prefix(8))", text: output),
                              preview: SharePreview("Tool output")) {
                        Label("Share Output…", systemImage: "square.and.arrow.up")
                    }
                }
            }
            if tool.arguments != nil || tool.output != nil {
                Button("Copy All", systemImage: "doc.on.doc") {
                    let fence = "```"
                    copyToolPayload("### \(tool.name)\n\n\(fence)json\n\(tool.arguments ?? "")\n\(fence)\n\n\(fence)\n\(tool.output ?? "")\n\(fence)")
                }
            }
            Toggle("Wrap Lines", systemImage: "text.word.spacing", isOn: $wrapsLines)
        }
    }
}
