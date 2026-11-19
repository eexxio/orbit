import SwiftUI

struct SlashCommandMenu: View {
    let query: String
    let commands: [HermesCommand]
    let isFallback: Bool
    let maximumHeight: CGFloat
    let unavailable: (HermesCommand) -> String?
    let dismiss: () -> Void
    let selectSnippet: (PromptSnippet) -> Void
    let selectCommand: (HermesCommand) -> Void
    let manage: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var contentHeight: CGFloat = 180
    private var store: PromptSnippetStore { HermesClient.shared.snippetStore }

    private func matches(_ text: String) -> Bool {
        query.isEmpty || PromptSnippetStore.folded(text).contains(PromptSnippetStore.folded(query))
    }
    private var snippets: [PromptSnippet] { store.snippets.filter { matches($0.name) } }
    private var filteredCommands: [HermesCommand] { commands.filter { matches($0.name) || $0.aliases.contains(where: matches) } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Slash shortcuts").font(.headline).accessibilityAddTraits(.isHeader)
                Spacer()
                Button(action: dismiss) { Image(systemName: "xmark").frame(width: 44, height: 44) }
                    .accessibilityLabel("Dismiss suggestions").accessibilityIdentifier("slash.dismiss")
            }
            .padding(.leading, 12)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Color.clear.frame(height: 0).id("start")
                        if !snippets.isEmpty || (query.isEmpty && store.snippets.isEmpty) {
                            heading("SNIPPETS")
                            if store.snippets.isEmpty {
                                state("No saved snippets", detail: "Save prompts you use often.", id: "slash.empty")
                            }
                            ForEach(snippets) { snippet in
                                row(snippet.name, detail: snippet.preview, icon: "text.alignleft", monospaced: false) { selectSnippet(snippet) }
                                    .accessibilityLabel("\(snippet.name), saved snippet")
                                    .accessibilityHint("Inserts into draft")
                                    .accessibilityIdentifier("slash.snippet.\(snippet.name)")
                            }
                        }
                        if !filteredCommands.isEmpty {
                            heading("COMMANDS").accessibilityIdentifier("slash.commands")
                            ForEach(filteredCommands) { command in
                                let reason = unavailable(command)
                                let detail = reason ?? (isFallback && !command.isLocal ? "Availability varies by server" : command.summary)
                                row("/\(command.name)", detail: detail,
                                    icon: command.isLocal ? "questionmark.circle" : "chevron.left.forwardslash.chevron.right",
                                    monospaced: true) { selectCommand(command) }
                                    .disabled(reason != nil)
                                    .accessibilityLabel("Slash \(command.name), \(detail), \(command.isLocal ? "Orbit help" : "Hermes command")")
                                    .accessibilityHint("Select, then Run")
                                    .accessibilityIdentifier("slash.command.\(command.name)")
                            }
                        }
                        if snippets.isEmpty && filteredCommands.isEmpty {
                            state("No shortcuts found", detail: "Keep typing to write a message.", id: "slash.noMatch")
                        }
                    }
                    .background {
                        GeometryReader { proxy in
                            Color.clear.onAppear { contentHeight = proxy.size.height }
                                .onChange(of: proxy.size.height) { _, height in contentHeight = height }
                        }
                    }
                }
                .frame(height: min(contentHeight, max(44, maximumHeight - 96)))
                .onChange(of: query) { proxy.scrollTo("start", anchor: .top) }
            }
            Divider()
            Button(action: manage) {
                HStack {
                    Text(store.snippets.isEmpty ? "New snippet" : "Manage snippets")
                    Spacer()
                    Image(systemName: store.snippets.isEmpty ? "plus" : "chevron.forward").accessibilityHidden(true)
                }
                .frame(minHeight: 44).contentShape(.rect)
            }
            .padding(.horizontal, 12)
            .accessibilityIdentifier(store.snippets.isEmpty ? "slash.newSnippet" : "slash.manageSnippets")
        }
        .foregroundStyle(.primary).tint(.primary)
        .background(.regularMaterial, in: .rect(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).stroke(.separator.opacity(0.5), lineWidth: 0.5) }
        .padding(.horizontal, 16)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("slash.menu")
        .onAppear {
            UIAccessibility.post(notification: .announcement, argument: "Suggestions available. \(snippets.count + filteredCommands.count) results.")
        }
    }

    private func heading(_ text: String) -> some View {
        Text(text).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 12).padding(.vertical, 6).accessibilityAddTraits(.isHeader)
    }

    private func state(_ title: String, detail: String, id: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.body)
            Text(detail).font(.footnote).foregroundStyle(.secondary)
        }.padding(12).accessibilityIdentifier(id)
    }

    private func row(_ title: String, detail: String, icon: String, monospaced: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).frame(width: 22).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(monospaced ? .system(.body, design: .monospaced) : .body)
                    Text(detail).font(.footnote).foregroundStyle(.secondary).lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                }
                Spacer(minLength: 0)
            }
            .frame(minHeight: 28).padding(.horizontal, 12).padding(.vertical, 8).contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}
