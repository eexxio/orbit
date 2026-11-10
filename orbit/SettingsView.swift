import SwiftUI

struct SettingsView: View {

    @Bindable private var client = HermesClient.shared
    @State private var showAccessToken = false

    var body: some View {

        NavigationStack {

            List {

                Section {
                    TextField("https://machine.tailnet.ts.net", text: $client.address)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    TextField("Username", text: $client.username)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    SecureField("Password", text: $client.password)
                        .textContentType(.password)
                } header: {
                    Text("Hermes Server")
                } footer: {
                    Text("The address of your Hermes Agent dashboard (`hermes dashboard`). Leave username and password empty if the dashboard has no sign-in.")
                }

                Section {
                    DisclosureGroup("Cloudflare Access", isExpanded: $showAccessToken) {
                        TextField("Client ID", text: $client.accessClientID)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField("Client Secret", text: $client.accessClientSecret)
                    }
                }

                Section {
                    HStack {
                        Text("Status")
                        Spacer()
                        statusLabel
                    }

                    if let version = client.serverVersion, client.state == .connected {
                        HStack {
                            Text("Hermes")
                            Spacer()
                            Text(version).foregroundStyle(.secondary)
                        }
                    }

                    Button {
                        Task { await client.connect() }
                    } label: {
                        Text(client.state == .connected ? "Reconnect" : "Connect")
                    }
                    .disabled(!client.isConfigured || client.state == .connecting)

                    if client.state == .connected {
                        Button("Disconnect", role: .destructive) {
                            client.disconnect()
                        }
                    }
                }

                Section {
                    Text("Account")
                    Text("Notifications")
                    Text("Appearance")
                    Text("Privacy")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch client.state {
        case .disconnected:
            Text("Not connected").foregroundStyle(.secondary)
        case .connecting:
            ProgressView()
        case .connected:
            Label("Connected", systemImage: "checkmark.circle.fill")
                .labelStyle(.titleAndIcon)
                .foregroundStyle(.green)
        case .failed(let message):
            Text(message)
                .foregroundStyle(.red)
                .multilineTextAlignment(.trailing)
                .font(.footnote)
        }
    }
}

#Preview {
    SettingsView()
}
