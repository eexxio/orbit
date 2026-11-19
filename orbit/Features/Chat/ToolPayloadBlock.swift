import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

struct ToolSectionTitle: View {
    let title: String

    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .accessibilityAddTraits(.isHeader)
    }
}

struct ToolPayloadBlock: View {
    let title: String
    let id: String
    let raw: String?
    let placeholder: String
    var waiting = false
    let wide: Bool
    let wraps: Bool
    @State private var preview: ToolPayloadPreview?
    @State private var expanded = false
    @State private var showSpinner = false
    @State private var copyCount = 0
    @State private var copied = false
    @ScaledMetric(relativeTo: .footnote) private var codeInset = 12.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var hasValue: Bool {
        guard let preview else { return false }
        return !preview.full.isEmpty && !(id == "input" && preview.full == "{}")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            let layout = dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading)) : AnyLayout(HStackLayout())
            layout {
                ToolSectionTitle(title)
                if !dynamicTypeSize.isAccessibilitySize { Spacer() }
                if id == "output", let preview, hasValue {
                    Text("\(preview.bytes.formatted(.byteCount(style: .file))) · \(preview.lineCount) \(preview.lineCount == 1 ? "line" : "lines")")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if let preview, hasValue {
                    Button {
                        copyToolPayload(preview.full, format: false)
                        copyCount += 1
                        copied = true
                    } label: {
                        let label = Label("Copy \(title.lowercased())", systemImage: copied ? "checkmark" : "doc.on.doc")
                        Group {
                            if wide { label.labelStyle(.titleAndIcon) }
                            else { label.labelStyle(.iconOnly) }
                        }
                        .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("tool.details.copy.\(id)")
                }
            }
            if let preview, hasValue {
                code(preview)
            } else if raw == nil || preview != nil {
                HStack(spacing: 8) {
                    if waiting { ProgressView().controlSize(.small).accessibilityHidden(true) }
                    Text(placeholder)
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("tool.details.\(id)")
            } else if showSpinner {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: raw) {
            preview = nil
            expanded = false
            showSpinner = false
            guard let raw else { return }
            let work = Task.detached(priority: .userInitiated) { ToolPayloadPreview(raw) }
            let delay = Task {
                try? await Task.sleep(for: .milliseconds(150))
                if !Task.isCancelled { showSpinner = true }
            }
            let result = await work.value
            delay.cancel()
            guard !Task.isCancelled else { return }
            preview = result
            showSpinner = false
        }
        .task(id: copyCount) {
            try? await Task.sleep(for: .seconds(1.5))
            if !Task.isCancelled { copied = false }
        }
        .sensoryFeedback(.success, trigger: copyCount)
    }

    private func code(_ preview: ToolPayloadPreview) -> some View {
        let collapsed = preview.lineCount > 24 && !expanded
        let shown = collapsed ? preview.collapsed : preview.expanded
        let fill = Color(uiColor: .secondarySystemBackground)
        return VStack(spacing: 0) {
            Group {
                if wraps {
                    codeText(shown)
                } else {
                    ScrollView(.horizontal) { codeText(shown).fixedSize(horizontal: true, vertical: false) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) {
                if collapsed {
                    LinearGradient(colors: [fill.opacity(0), fill], startPoint: .top, endPoint: .bottom)
                        .frame(height: 32)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityValue(String(shown.prefix(500)))
            .accessibilityIdentifier("tool.details.\(id)")
            .accessibilityAction(named: Text("Copy")) { copyToolPayload(preview.full, format: false) }
            if collapsed {
                Button("Show All \(preview.lineCount) Lines") {
                    withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) { expanded = true }
                }
                .font(.subheadline)
                .frame(maxWidth: .infinity, minHeight: 44)
                .accessibilityIdentifier("tool.details.showAll")
            }
        }
        .background(fill, in: .rect(cornerRadius: 12))
        .overlay(alignment: .bottom) {
            if expanded && preview.omitted {
                Text("Showing a preview. Copy for the full text.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(6)
                    .background(fill)
            }
        }
    }

    private func codeText(_ text: String) -> some View {
        Text(verbatim: text)
            .font((wide ? Font.callout : .footnote).monospaced())
            .textSelection(.enabled)
            .padding(codeInset)
    }
}

struct ToolPayloadPreview: Sendable {
    let full: String
    let collapsed: String
    let expanded: String
    let bytes: Int
    let lineCount: Int
    let omitted: Bool

    nonisolated init(_ raw: String) {
        let full = Self.clean(raw)
        self.full = full
        bytes = full.utf8.count
        let lines = full.split(separator: "\n", omittingEmptySubsequences: false)
        lineCount = lines.count
        var visible: [String] = []
        var remaining = 200_000
        var cut = false
        for line in lines.prefix(2_000) {
            guard remaining > 0 else { break }
            let fragment = line.utf8.prefix(min(10_000, remaining))
            let truncated = fragment.count < line.utf8.count
            visible.append(String(decoding: fragment, as: UTF8.self) + (truncated ? "… (line truncated)" : ""))
            remaining -= fragment.count + 1
            cut = cut || truncated
        }
        omitted = cut || visible.count < lines.count
        collapsed = visible.prefix(24).joined(separator: "\n")
        expanded = visible.joined(separator: "\n")
    }

    nonisolated static func clean(_ raw: String, format: Bool = true) -> String {
        let plain = raw.replacingOccurrences(of: #"\x1b(?:\[[0-?]*[ -/]*[@-~]|\][^\x07\x1b]*(?:\x07|\x1b\\))"#,
                                              with: "", options: .regularExpression)
        guard format, plain.utf8.count <= 1_000_000,
              let json = try? JSONSerialization.jsonObject(with: Data(plain.utf8)),
              let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return plain }
        if (json as? [String: Any])?.isEmpty == true { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}

@MainActor func copyToolPayload(_ value: String, format: Bool = true) {
    Task {
        let plain = await Task.detached { ToolPayloadPreview.clean(value, format: format) }.value
        UIPasteboard.general.string = plain
        AccessibilityNotification.Announcement("Copied").post()
    }
}

struct ToolOutputFile: Transferable, Sendable {
    let name: String
    let text: String

    nonisolated static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .plainText) { output in
            Data(ToolPayloadPreview.clean(output.text).utf8)
        }
        .suggestedFileName { $0.name }
    }
}
