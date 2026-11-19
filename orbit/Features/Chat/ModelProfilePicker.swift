import SwiftUI

struct ChatModelTitle: View {
    let chat: LiveChat
    let onOpen: () -> Void
    let onNewChat: (String?) -> Void

    @Environment(\.horizontalSizeClass) private var width
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var presented = false

    private var regular: Bool { width == .regular }
    private var usePopover: Bool { regular && typeSize < .accessibility3 }
    private var fullModel: String? {
        chat.selectedModel?.name ?? chat.currentModel
            ?? (chat.isDraft ? draftDefault : nil)
    }
    private var draftDefault: String? {
        let client = HermesClient.shared
        return client.modelCatalogs[chat.profile]?.currentModel
            ?? client.profiles.first { $0.name == chat.profile }?.model
    }
    private var showProfile: Bool { HermesClient.shared.profiles.count != 1 }

    var body: some View {
        Button {
            onOpen()
            presented = true
        } label: {
            VStack(spacing: 2) {
                Text(chat.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Image(systemName: "cpu").font(.system(size: 12))
                    Text(fullModel.map(shortModelName) ?? "Model")
                        .truncationMode(.middle)
                    if chat.pendingModel != nil || chat.changingModel != nil {
                        Image(systemName: "clock").font(.system(size: 10))
                    }
                    if showProfile && !typeSize.isAccessibilitySize { Text("· \(chat.profile)") }
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(presented && !reduceMotion ? 180 : 0))
                }
                .font(regular ? .subheadline : .caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .contentTransition(.opacity)
            }
            .frame(minWidth: 44, minHeight: 44)
            .frame(maxWidth: regular ? 360 : 220)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .keyboardShortcut("m", modifiers: [.command, .shift])
        .accessibilityLabel(accessibilityTitle)
        .accessibilityHint("Double-tap to change.")
        .accessibilityIdentifier("chat.modelSwitcher")
        .animation(.snappy(duration: reduceMotion ? 0 : 0.25), value: fullModel)
        .animation(.snappy(duration: reduceMotion ? 0 : 0.25), value: presented)
        .sheet(isPresented: presentation(popover: false)) {
            picker
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(Color(uiColor: .systemGroupedBackground))
        }
        .popover(isPresented: presentation(popover: true), arrowEdge: .top) {
            picker
                .frame(width: 420, height: 560)
                .presentationCompactAdaptation(.sheet)
                .presentationBackground(Color(uiColor: .systemGroupedBackground))
        }
        .onChange(of: chat.modelConfirmation?.id) { _, id in
            if id != nil { presented = true }
        }
    }

    private var accessibilityTitle: String {
        var title = fullModel.map { "Model, \($0)" } ?? "Model"
        if showProfile { title += ", profile \(chat.profile)" }
        if let pending = chat.pendingModel { title += ", next message \(pending.name)" }
        return title
    }

    private func presentation(popover: Bool) -> Binding<Bool> {
        Binding(get: { presented && usePopover == popover }, set: { if !$0 { presented = false } })
    }

    private var picker: some View {
        ModelProfilePicker(chat: chat, regular: usePopover) { profile in
            presented = false
            if let profile { onNewChat(profile) }
        }
    }
}

struct ModelProfilePicker: View {
    @Bindable var chat: LiveChat
    let regular: Bool
    let onClose: (String?) -> Void

    @State private var search = ""
    @State private var showAll: Set<String> = []
    @State private var catalog: HermesModelCatalog?
    @State private var loading = true
    @State private var offline = false
    @State private var listError: String?
    @State private var showProfiles = false
    @State private var selection = 0
    @State private var applied = 0
    @State private var refused = 0
    @ScaledMetric(relativeTo: .body) private var padRowSize = 19

    private var client: HermesClient { HermesClient.shared }
    private var modelCatalog: HermesModelCatalog? { catalog ?? client.modelCatalogs[chat.profile] }
    private var options: [HermesModelOption] { modelCatalog?.options ?? [] }
    private var defaultModel: String? {
        client.profiles.first { $0.name == chat.profile }?.model
            ?? client.modelCatalogs[chat.profile]?.currentModel
    }
    private var defaultOption: HermesModelOption? {
        options.first { $0.name == defaultModel }
    }
    private var actionsDisabled: Bool { offline || chat.changingModel != nil || chat.isProfileGone }

    var body: some View {
        NavigationStack {
            list
                .navigationTitle("Chat Settings")
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(Color(uiColor: .systemGroupedBackground), for: .navigationBar)
                .toolbarBackgroundVisibility(.visible, for: .navigationBar)
                .toolbar {
                    if loading {
                        ToolbarItem(placement: .topBarLeading) { ProgressView().controlSize(.small) }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { chat.modelConfirmation = nil; onClose(nil) }
                            .accessibilityIdentifier("modelPicker.done")
                    }
                }
                .navigationDestination(isPresented: $showProfiles) {
                    List {
                        ForEach(client.profiles.filter { $0.name != chat.profile }) { profile in
                            profileButton(profile) { onClose(profile.name) }
                        }
                    }
                    .listStyle(.insetGrouped)
                    .navigationTitle("New chat in")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbarBackground(Color(uiColor: .systemGroupedBackground), for: .navigationBar)
                    .toolbarBackgroundVisibility(.visible, for: .navigationBar)
                }
        }
        .task {
            if let profiles = try? await client.chatProfiles(), !Task.isCancelled {
                chat.checkProfiles(profiles)
            }
        }
        .task(id: chat.profile) {
            catalog = nil
            showAll = []
            await loadModels()
        }
        .sensoryFeedback(.selection, trigger: selection)
        .sensoryFeedback(.success, trigger: applied)
        .sensoryFeedback(.error, trigger: refused)
        .confirmationDialog(
            "Use \(chat.modelConfirmation?.option.displayName ?? "this model")?",
            isPresented: Binding(get: { chat.modelConfirmation != nil }, set: { if !$0 { chat.modelConfirmation = nil } }),
            titleVisibility: .visible,
            presenting: chat.modelConfirmation
        ) { confirmation in
            Button("Use \(confirmation.option.displayName)") {
                pick(confirmation.option, confirmation: confirmation)
            }
            Button("Cancel", role: .cancel) { chat.modelConfirmation = nil }
        } message: { confirmation in
            Text(confirmation.message)
        }
    }

    @ViewBuilder
    private var list: some View {
        if options.count > 8 {
            rows.searchable(text: $search, prompt: "Search models")
        } else {
            rows
        }
    }

    private var rows: some View {
        List {
            if offline {
                Label("Offline — showing saved list", systemImage: "wifi.slash")
                    .foregroundStyle(.secondary)
            }
            if client.profiles.count > 1 && search.isEmpty { profileSection }
            modelSection
            ForEach(providerGroups, id: \.first?.provider) { models in
                if let provider = models.first {
                    Section(provider.providerName) {
                        let capped = search.isEmpty && !showAll.contains(provider.provider) && models.count > 20
                        ForEach(capped ? Array(models.prefix(20)) : models) { option in modelRow(option) }
                        if capped {
                            Button("Show all \(models.count)") { showAll.insert(provider.provider) }
                                .foregroundStyle(.primary)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .tint(.primary)
        .refreshable { await loadModels(refresh: true) }
        .symbolRenderingMode(.monochrome)
        .accessibilityIdentifier("modelPicker.list")
    }

    private var profileSection: some View {
        Section {
            if chat.isDraft {
                ForEach(client.profiles) { profile in
                    profileButton(profile) { chat.selectProfile(profile.name) }
                        .disabled(actionsDisabled)
                }
            } else {
                Label(chat.profile, systemImage: "lock")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("modelPicker.lockedProfile")
                Button { showProfiles = true } label: {
                    Label("New chat in another profile…", systemImage: "square.and.pencil")
                }
                .disabled(offline || chat.changingModel != nil)
                .accessibilityIdentifier("modelPicker.newChatInProfile")
            }
        } header: {
            Text("Profile")
        } footer: {
            if !chat.isDraft { Text("A chat stays in the profile it started in.") }
        }
    }

    private var modelSection: some View {
        Section {
            if search.isEmpty {
                Button { pick(chat.isDraft ? nil : defaultOption) } label: {
                    row("Profile default", subtitle: defaultModel, selected: chat.isDraft && chat.selectedModel == nil)
                }
                .disabled(actionsDisabled || (!chat.isDraft && defaultOption == nil))
                .accessibilityIdentifier("modelPicker.default")
            }
            if let listError {
                Label(listError, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("modelPicker.listError")
                Button("Try Again", systemImage: "arrow.clockwise") { Task { await loadModels() } }
            } else if loading && modelCatalog == nil {
                ForEach(0..<3) { _ in
                    Text("Model name").redacted(reason: .placeholder).accessibilityHidden(true)
                }
            } else if options.isEmpty {
                Text("No models are set up. Add a provider in the Hermes dashboard.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("modelPicker.noModels")
            }
            if !chat.isDraft, let current = chat.currentModel, !options.contains(where: chat.isCurrent),
               !loading || modelCatalog != nil {
                HStack {
                    if listError == nil { Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange) }
                    row(shortModelName(current), subtitle: listError == nil ? "Not available on the server any more" : current,
                        selected: true)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("modelPicker.unavailable")
            }
        } header: {
            Text("Model")
        } footer: {
            Text(chat.isDraft ? "Used for this chat’s first message." : "Applies from your next message.")
        }
    }

    private func profileButton(_ profile: HermesChatProfile, action: @escaping () -> Void) -> some View {
        let selected = chat.profile == profile.name
        return Button {
            selection += 1
            action()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "person.crop.circle").font(.system(size: regular ? 20 : 17))
                row(profile.name, subtitle: profile.description, selected: selected)
            }
        }
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityIdentifier("profileRow.\(profile.name)")
    }

    private func modelRow(_ option: HermesModelOption) -> some View {
        let selected = chat.isCurrent(option)
        let queued = chat.pendingModel == option
        return VStack(alignment: .leading, spacing: 2) {
            Button { pick(option) } label: {
                row(option.displayName, subtitle: option.displayName != option.name ? option.name : nil,
                    selected: selected, busy: chat.changingModel == option, queued: queued)
            }
            .buttonStyle(.plain)
            .disabled(actionsDisabled)
            .accessibilityLabel("\(option.name), \(option.providerName)")
            .accessibilityValue(queued ? "Pending" : selected ? "Selected" : "")
            .accessibilityAddTraits(selected ? [.isSelected] : [])
            .accessibilityIdentifier("modelRow.\(option.name)")
            if chat.failedModel == option, let error = chat.modelError {
                Text(error.components(separatedBy: ". ").first ?? error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .padding(.bottom, 4)
                    .accessibilityIdentifier("modelPicker.switchError")
            }
        }
    }

    private func row(_ title: String, subtitle: String?, selected: Bool, busy: Bool = false, queued: Bool = false) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(regular ? .system(size: padRowSize) : .body)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 4)
            if busy { ProgressView().controlSize(.small) }
            else if queued { Image(systemName: "clock").accessibilityHidden(true) }
            else if selected { Image(systemName: "checkmark").font(.body.weight(.semibold)).accessibilityHidden(true) }
        }
        .frame(minHeight: regular ? 52 : 44)
        .contentShape(.rect)
    }

    private var providerGroups: [[HermesModelOption]] {
        var groups: [[HermesModelOption]] = []
        var indexes: [String: Int] = [:]
        for option in options where search.isEmpty || option.name.localizedCaseInsensitiveContains(search)
            || option.providerName.localizedCaseInsensitiveContains(search) {
            if let index = indexes[option.provider] { groups[index].append(option) }
            else {
                indexes[option.provider] = groups.count
                groups.append([option])
            }
        }
        return groups
    }

    private func loadModels(refresh: Bool = false) async {
        let profile = chat.profile
        loading = true
        listError = nil
        offline = false
        defer { if profile == chat.profile && !Task.isCancelled { loading = false } }
        do {
            let fresh = try await chat.availableModels(refresh: refresh)
            guard profile == chat.profile, !Task.isCancelled else { return }
            catalog = fresh
        } catch {
            guard profile == chat.profile, !Task.isCancelled else { return }
            offline = error is URLError || client.state == .disconnected
            if case HermesError.modelListNeedsRestart = error { listError = error.localizedDescription }
            else { listError = "Couldn’t load models." }
        }
    }

    private func pick(_ option: HermesModelOption?, confirmation: HermesModelConfirmation? = nil) {
        selection += 1
        Task {
            if await chat.pickModel(option, confirmation: confirmation) {
                applied += 1
                onClose(nil)
            } else if chat.modelError != nil {
                refused += 1
            }
        }
    }
}

struct ModelChangeRow: View {
    let model: String
    let pending: Bool

    @Environment(\.horizontalSizeClass) private var width
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let name = shortModelName(model)
        HStack(spacing: 8) {
            line
            Label(pending ? "Next message uses \(name)" : "Switched to \(name)", systemImage: pending ? "clock" : "cpu")
                .font(width == .regular ? .footnote : .caption)
                .layoutPriority(1)
            line
        }
        .foregroundStyle(.secondary)
        .padding(.vertical, width == .regular ? 14 : 12)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(pending ? "Next message uses \(model)" : "Model switched to \(model)")
        .accessibilityIdentifier(pending ? "chat.modelPending" : "chat.modelChanged")
        .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96)))
    }

    private var line: some View {
        Rectangle().fill(.secondary.opacity(0.3))
            .frame(height: 0.5)
            .frame(minWidth: 8)
            .accessibilityHidden(true)
    }
}

private func shortModelName(_ model: String) -> String {
    model.split(separator: "/").last.map(String.init) ?? model
}
