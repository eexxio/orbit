import SwiftUI

struct SlashCommandMenu: View {
    let query: String
    let commands: [HermesCommand]
    let select: (String) -> Void
    let newSnippet: () -> Void

    private func matches(_ text: String) -> Bool {
        query.isEmpty || text.localizedCaseInsensitiveContains(query)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Snippets").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(10)
                ForEach(HermesClient.shared.snippets.filter { matches($0.title) || matches($0.body) }) { snippet in
                    row(snippet.title, detail: snippet.body, icon: "text.quote") { select(snippet.body) }
                        .accessibilityIdentifier("slash.snippet.\(snippet.title)")
                }
                Text("Hermes commands").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(10)
                ForEach(commands.filter { matches($0.name) || matches($0.summary) }) { command in
                    row("/\(command.name)", detail: command.summary, icon: "terminal") { select("/\(command.name) ") }
                        .accessibilityIdentifier("slash.command.\(command.name)")
                }
                Button(action: newSnippet) {
                    Label("New snippet…", systemImage: "plus").frame(maxWidth: .infinity, alignment: .leading).padding(12)
                }
                .accessibilityIdentifier("slash.newSnippet")
            }
        }
        .frame(maxHeight: 280)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .accessibilityIdentifier("slash.menu")
    }

    private func row(_ title: String, detail: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).frame(width: 22).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline.weight(.medium))
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}
