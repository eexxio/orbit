import SwiftUI

enum ChatShortcut: CaseIterable {
    case newChat, newWindow, openChat, toggleSidebar, findChat
    case focusComposer, send, stop, settings, showShortcuts

    enum Group: String, CaseIterable {
        case file = "File", view = "View", chat = "Chat", orbit = "Orbit", help = "Help"
    }

    var group: Group {
        switch self {
        case .newChat, .newWindow, .openChat: .file
        case .toggleSidebar, .findChat: .view
        case .focusComposer, .send, .stop: .chat
        case .settings: .orbit
        case .showShortcuts: .help
        }
    }

    var title: LocalizedStringKey {
        switch self {
        case .newChat: "New Chat"
        case .findChat: "Search Chats"
        case .newWindow: "New Window"
        case .openChat: "Open Chat in New Window"
        case .toggleSidebar: "Show/Hide Sidebar"
        case .focusComposer: "Focus Composer"
        case .send: "Send Message"
        case .stop: "Stop Reply"
        case .settings: "Settings"
        case .showShortcuts: "Keyboard Shortcuts"
        }
    }

    var key: KeyEquivalent {
        switch self {
        case .newChat, .newWindow: "n"
        case .findChat: "f"
        case .openChat: "o"
        case .toggleSidebar: "0"
        case .focusComposer: "l"
        case .send: .return
        case .stop: "."
        case .settings: ","
        case .showShortcuts: "/"
        }
    }

    var modifiers: EventModifiers {
        switch self {
        case .newWindow: [.command, .shift]
        case .openChat: [.command, .option]
        default: .command
        }
    }

    var keys: String {
        let symbol = self == .send ? "↩" : String(key.character).uppercased()
        return (modifiers.contains(.shift) ? "⇧" : "") + (modifiers.contains(.option) ? "⌥" : "") + "⌘" + symbol
    }
}

struct ChatWindowActions {
    let available: (ChatShortcut) -> Bool
    let label: (ChatShortcut) -> LocalizedStringKey
    let perform: (ChatShortcut) -> Void
}

extension FocusedValues {
    @Entry var chatWindowActions: ChatWindowActions?
}

struct ChatCommands: Commands {
    @FocusedValue(\.chatWindowActions) private var actions

    var body: some Commands {
        CommandGroup(replacing: .newItem) { buttons(.file) }
        CommandMenu("View") { buttons(.view) }
        CommandMenu("Chat") { buttons(.chat) }
        CommandGroup(after: .appSettings) { buttons(.orbit) }
        CommandGroup(replacing: .help) { buttons(.help) }
    }

    @ViewBuilder private func buttons(_ group: ChatShortcut.Group) -> some View {
        if let actions {
            ForEach(ChatShortcut.allCases.filter { $0.group == group }, id: \.self) { shortcut in
                Button(actions.label(shortcut)) { actions.perform(shortcut) }
                    .disabled(!actions.available(shortcut))
            }
        }
    }
}

struct ChatShortcutBindings: View {
    let actions: ChatWindowActions

    var body: some View {
        ZStack {
            ForEach(ChatShortcut.allCases, id: \.self) { shortcut in
                if actions.available(shortcut) {
                    Button(actions.label(shortcut)) { actions.perform(shortcut) }
                        .keyboardShortcut(shortcut.key, modifiers: shortcut.modifiers)
                }
            }
        }
        .frame(width: 0, height: 0)
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct ChatShortcutSheet: View {
    @Environment(\.dismiss) private var dismiss
    let available: (ChatShortcut) -> Bool

    var body: some View {
        NavigationStack {
            ShortcutRows(available: available)
            .navigationTitle("Keyboard Shortcuts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.escape, modifiers: [])
                        .accessibilityIdentifier("chats.shortcuts.done")
                }
            }
        }
        .accessibilityIdentifier("chats.shortcuts.sheet")
    }
}

struct ShortcutRows: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let available: (ChatShortcut) -> Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(ChatShortcut.Group.allCases, id: \.self) { group in
                    Text(LocalizedStringKey(group.rawValue))
                        .font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(ChatShortcut.allCases.filter { $0.group == group }, id: \.self) { shortcut in
                        let enabled = available(shortcut)
                        let layout = typeSize.isAccessibilitySize
                            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
                            : AnyLayout(HStackLayout(spacing: 16))
                        layout {
                            Text(shortcut.title).font(.body).frame(maxWidth: .infinity, alignment: .leading)
                            Text(shortcut.keys).font(.subheadline.monospaced())
                        }
                        .frame(minHeight: 36)
                        .foregroundStyle(enabled ? .primary : .secondary)
                        .accessibilityElement(children: .combine)
                        .accessibilityHint(enabled ? "" : "Unavailable")
                    }
                }
            }
            .padding(20)
        }
    }
}
