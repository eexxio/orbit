import SwiftUI

struct SettingsView: View {

    @Bindable private var client = HermesClient.shared
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppearanceKey.accent) private var accent = Accent.mono
    @AppStorage(AppearanceKey.theme) private var theme = Theme.system

    var body: some View {

        NavigationStack {

            Form {

                Section {
                    BrandHeader(state: client.state, host: client.baseURL?.host())
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())

                serverSection
                connectionSection
                agentSection
                appearanceSection
                aboutSection
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .close) { dismiss() }
                }
            }
        }
        // Sheets don't inherit the app's tint, so apply it here too, live as the swatches change.
        .tint(accent.color)
    }

    private var serverSection: some View {

        Section {
            SettingsField(icon: "server.rack") {
                TextField("https://machine.tailnet.ts.net", text: $client.address)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            SettingsField(icon: "person") {
                TextField("Username", text: $client.username)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            SettingsField(icon: "key") {
                SecureField("Password", text: $client.password)
                    .textContentType(.password)
            }
            NavigationLink {
                CloudflareAccessView()
            } label: {
                SettingsField(icon: "cloud") {
                    LabeledContent("Cloudflare Access", value: client.accessClientID.isEmpty ? "Off" : "On")
                }
            }
        } header: {
            Text("Server")
        } footer: {
            Text("The address of your Hermes Agent dashboard (`hermes dashboard`). Leave username and password empty if the dashboard has no sign-in.")
        }
    }

    private var connectionSection: some View {

        Section("Connection") {

            if case .failed(let message) = client.state {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            if client.state == .connected, let version = client.serverVersion {
                LabeledContent("Hermes", value: version)
            }

            Button {
                Task { await client.connect() }
            } label: {
                HStack {
                    Text(client.state == .connected ? "Reconnect" : "Connect")
                    Spacer()
                    if client.state == .connecting { ProgressView() }
                }
            }
            .disabled(!client.isConfigured || client.state == .connecting)

            if client.state == .connected {
                Button("Disconnect", role: .destructive) {
                    client.disconnect()
                }
            }
        }
    }

    private var agentSection: some View {

        Section {
            LabeledContent("Profile", value: client.profile)
            NavigationLink {
                SoulEditorView()
            } label: {
                SettingsField(icon: "sparkles") {
                    Text("Personality")
                }
            }
            .disabled(client.state != .connected)
        } header: {
            Text("Agent")
        } footer: {
            Text(client.state == .connected
                 ? "Edit SOUL.md, the persona Hermes uses for this profile."
                 : "Connect to edit the agent's SOUL.md.")
        }
    }

    private var appearanceSection: some View {

        Section("Appearance") {
            Picker("Theme", selection: $theme) {
                ForEach(Theme.allCases) { Text($0.name).tag($0) }
            }
            .pickerStyle(.segmented)
            .listRowSeparator(.hidden)

            AccentPicker(selection: $accent)
        }
    }

    private var aboutSection: some View {

        Section {
            LabeledContent("Version", value: Self.appVersion)
            Link(destination: URL(string: "https://github.com/eexxio/orbit")!) {
                HStack {
                    Text("Source Code")
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
        } header: {
            Text("About")
        } footer: {
            Text("orbit is an independent client for Hermes Agent. Wordmark set in Monocraft by Idrees Hassan.")
        }
    }

    private static let appVersion: String = {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }()
}

/// The optional Cloudflare Access service token, on its own page since most setups don't need it.
private struct CloudflareAccessView: View {

    @Bindable private var client = HermesClient.shared

    var body: some View {
        Form {
            Section {
                SettingsField(icon: "person.badge.key") {
                    TextField("Client ID", text: $client.accessClientID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                SettingsField(icon: "lock") {
                    SecureField("Client Secret", text: $client.accessClientSecret)
                }
            } footer: {
                Text("Only needed when the dashboard sits behind a Cloudflare Access service token. Both values are sent with every request. Reconnect after changing them.")
            }
        }
        .navigationTitle("Cloudflare Access")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The orbit lockup above the form, with the connection status as a pill underneath.
private struct BrandHeader: View {

    let state: HermesClient.State
    let host: String?

    var body: some View {

        VStack(spacing: 16) {

            // Pixel art: enlarge the 1× asset by a whole number only, with smoothing off (docs/brand).
            Image("Lockup")
                .resizable()
                .interpolation(.none)
                .aspectRatio(contentMode: .fit)
                .frame(width: 29 * 4)
                .accessibilityLabel("orbit")

            statusPill
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private var statusPill: some View {

        HStack(spacing: 6) {
            switch state {
            case .connecting:
                ProgressView().controlSize(.mini)
            default:
                Circle().fill(dotColor).frame(width: 7, height: 7)
            }
            Text(statusText)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.footnote.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.fill.tertiary, in: .capsule)
        .accessibilityElement(children: .combine)
    }

    private var statusText: String {
        switch state {
        case .disconnected: "Not connected"
        case .connecting: "Connecting…"
        case .connected: host.map { "Connected to \($0)" } ?? "Connected"
        case .failed: "Couldn't connect"
        }
    }

    private var dotColor: Color {
        switch state {
        case .connected: .green
        case .failed: .red
        default: .secondary
        }
    }
}

/// A form row with a fixed-width leading symbol, so fields line up under each other.
private struct SettingsField<Content: View>: View {

    let icon: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 22)
            content
        }
    }
}

#Preview {
    SettingsView()
}
