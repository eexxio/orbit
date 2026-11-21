import SwiftUI

/// The first-launch flow: Welcome, Connect your server, Connected. Shown while no server is saved;
/// it signs in through `HermesClient.connect()` with the same fields and storage as Settings.
struct OnboardingView: View {

    enum Step: Hashable { case connect, connected }

    /// Called when the user leaves; `startChat` is true when they asked for their first chat.
    let onFinish: (_ startChat: Bool) -> Void

    @AppStorage(AppearanceKey.accent) private var accent = Accent.mono
    @State private var path: [Step]

    init(startingAt step: Step? = nil, onFinish: @escaping (_ startChat: Bool) -> Void) {
        self.onFinish = onFinish
        _path = State(initialValue: step.map { [$0] } ?? [])
    }

    var body: some View {
        NavigationStack(path: $path) {
            OnboardingWelcome(getStarted: { path.append(.connect) }, later: { onFinish(false) })
                .navigationDestination(for: Step.self) { step in
                    switch step {
                    case .connect: OnboardingConnect { path.append(.connected) }
                    case .connected: OnboardingConnected { onFinish(true) }
                    }
                }
        }
        // A full-screen cover doesn't inherit the app's tint.
        .tint(accent.color)
    }
}

// MARK: - Welcome

private struct OnboardingWelcome: View {

    let getStarted: () -> Void
    let later: () -> Void

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 0) {
                    // Pixel art: enlarge the 1× asset by a whole number only, with smoothing off (docs/brand).
                    Image("Lockup")
                        .resizable()
                        .interpolation(.none)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 29 * 6)
                        .accessibilityLabel("orbit")
                        .padding(.bottom, 24)

                    Text("Chat with your Hermes agent")
                        .font(.title2.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("onboarding.welcome")
                        .padding(.bottom, 8)

                    Text("orbit needs a Hermes Agent dashboard to connect to.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center)
                .onboardingColumn()
                .padding(.top, typeSize.isAccessibilitySize ? 24 : geometry.size.height * 0.3)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(Color(.systemBackground))
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 12) {
                OnboardingPrimaryButton(title: "Get started", id: "onboarding.start", action: getStarted)
                Button("Set up later", action: later)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("onboarding.later")
            }
            .onboardingColumn()
            .padding(.vertical, 16)
            .background(Color(.systemBackground))
        }
        .toolbar(.hidden, for: .navigationBar)
    }
}

// MARK: - Connect

private struct OnboardingConnect: View {

    let connected: () -> Void

    private enum Field: Hashable { case address, username, password }

    @Bindable private var client = HermesClient.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var error: Error?
    @State private var connecting = false
    /// Applied once the form is enabled again; a disabled field can't take focus.
    @State private var focusAfterConnect: Field?
    @FocusState private var focus: Field?

    var body: some View {
        Form {
            Section {
                if let message = message(for: .address) { errorRow(message) }
                SettingsField(icon: "server.rack") {
                    TextField("https://machine.tailnet.ts.net", text: editing($client.address))
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.next)
                        .focused($focus, equals: .address)
                        .onSubmit(addressSubmitted)
                        .accessibilityIdentifier("onboarding.address")
                }
            } header: {
                Text("Server")
            } footer: {
                Text("Run `hermes dashboard` on your computer and enter the address it prints.")
            }

            Section {
                if let message = message(for: .password) { errorRow(message) }
                SettingsField(icon: "person") {
                    TextField("Username", text: editing($client.username))
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.next)
                        .focused($focus, equals: .username)
                        .onSubmit { focus = .password }
                        .accessibilityIdentifier("onboarding.username")
                }
                SettingsField(icon: "key") {
                    SecureField("Password", text: editing($client.password))
                        .textContentType(.password)
                        .submitLabel(.go)
                        .focused($focus, equals: .password)
                        .onSubmit(connect)
                        .accessibilityIdentifier("onboarding.password")
                }
            } header: {
                Text("Sign-in (optional)")
            } footer: {
                Text("Leave these empty if the dashboard has no sign-in.")
            }

            Section {
                NavigationLink {
                    CloudflareAccessView()
                } label: {
                    SettingsField(icon: "cloud") {
                        LabeledContent("Cloudflare Access") {
                            Text(client.accessClientID.isEmpty ? "Off" : "On")
                                .foregroundStyle(cloudflareHint ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                        }
                    }
                }
                .accessibilityIdentifier("onboarding.cloudflare")
            } footer: {
                if cloudflareHint {
                    Text("A 403 usually means Cloudflare Access turned orbit away. Add its service token here.")
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("onboarding.cloudflareHint")
                } else {
                    Text("Only if the dashboard is behind Cloudflare Access.")
                }
            }
        }
        .disabled(connecting)
        .frame(maxWidth: 440)
        .frame(maxWidth: .infinity)
        .navigationTitle("Connect your server")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            OnboardingPrimaryButton(title: "Connect", id: "onboarding.connect", busy: connecting, action: connect)
                .disabled(client.baseURL == nil || connecting)
                .accessibilityHint(client.baseURL == nil ? "Enter the server address first." : "")
                .onboardingColumn()
                .padding(.vertical, 16)
                // Solid, so the form's footers never show through behind the button.
                .background(Color(.systemGroupedBackground))
        }
        .sensoryFeedback(.error, trigger: error.map { $0.localizedDescription })
        .onAppear { if client.address.isEmpty { focus = .address } }
        .onChange(of: connecting) {
            guard !connecting, let field = focusAfterConnect else { return }
            focusAfterConnect = nil
            // Wait for the form to re-enable; a disabled field can't take focus.
            Task {
                try? await Task.sleep(for: .milliseconds(150))
                focus = field
            }
        }
        // Coming back from the Cloudflare page with a new token is an edit too.
        .onChange(of: client.accessClientID) { setError(nil) }
    }

    /// The message for an error, shown at the top of the section it belongs to.
    private func message(for field: Field) -> String? {
        guard let error else { return nil }
        let isPassword = if case HermesError.wrongPassword = error { true } else { false }
        guard isPassword == (field == .password) else { return nil }
        return error.localizedDescription
    }

    /// A 403 with no Cloudflare token set usually means Access turned the request away.
    private var cloudflareHint: Bool {
        guard case HermesError.http(403, _)? = error else { return false }
        return client.accessClientID.isEmpty
    }

    private func errorRow(_ message: String) -> some View {
        ErrorRow(message: message)
            .accessibilityIdentifier("onboarding.error")
            .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
    }

    /// Typing in any field clears the error it may have caused.
    private func editing(_ binding: Binding<String>) -> Binding<String> {
        Binding(get: { binding.wrappedValue }, set: { binding.wrappedValue = $0; setError(nil) })
    }

    private func setError(_ newValue: Error?) {
        guard newValue != nil || error != nil else { return }
        withAnimation(.snappy) { error = newValue }
        if let newValue { AccessibilityNotification.Announcement(newValue.localizedDescription).post() }
    }

    private func addressSubmitted() {
        if client.baseURL == nil, !client.address.trimmingCharacters(in: .whitespaces).isEmpty {
            setError(HermesError.invalidAddress)
        } else {
            focus = .username
        }
    }

    private func connect() {
        guard client.baseURL != nil, !connecting else { return }
        focus = nil
        setError(nil)
        withAnimation(.snappy) { connecting = true }
        AccessibilityNotification.Announcement("Connecting").post()
        Task {
            let failure = await client.connect()
            withAnimation(.snappy) { connecting = false }
            if let failure {
                // Leaving the app mid-request cancels it; the user just taps Connect again.
                if failure is CancellationError || (failure as? URLError)?.code == .cancelled { return }
                if case HermesError.wrongPassword = failure {
                    client.password = ""
                    focusAfterConnect = .password
                }
                setError(failure)
            } else if client.state == .connected {
                connected()
            }
        }
    }
}

// MARK: - Connected

private struct OnboardingConnected: View {

    let startChat: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drawn = false
    @State private var pillShown = false

    private var client: HermesClient { HermesClient.shared }
    private var host: String { client.baseURL?.host() ?? client.address }

    private var checkmark: some View {
        Image(systemName: "checkmark.circle")
            .font(.system(size: 56))
            .foregroundStyle(.secondary)
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 0) {
                    ZStack {
                        if drawn, reduceMotion {
                            checkmark.transition(.opacity)
                        } else if drawn {
                            checkmark.transition(.symbolEffect(.drawOn))
                        }
                    }
                    .frame(height: 68)
                    .accessibilityHidden(true)
                    .padding(.bottom, 16)

                    Text("You're connected")
                        .font(.title2.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("onboarding.connected")
                        .padding(.bottom, 12)

                    ConnectionPill(state: client.state, host: host)
                        .opacity(pillShown ? 1 : 0)
                        .padding(.bottom, 8)

                    if let version = client.serverVersion {
                        Text("Hermes \(version)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .multilineTextAlignment(.center)
                .onboardingColumn()
                .padding(.top, geometry.size.height * 0.3)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(Color(.systemBackground))
        .safeAreaInset(edge: .bottom) {
            OnboardingPrimaryButton(title: "Start your first chat", id: "onboarding.firstChat", action: startChat)
                .onboardingColumn()
                .padding(.vertical, 16)
                .background(Color(.systemBackground))
        }
        .navigationBarBackButtonHidden()
        .sensoryFeedback(.success, trigger: drawn) { _, new in new }
        .onAppear {
            withAnimation(.snappy) { drawn = true }
            withAnimation(.easeOut.delay(0.15)) { pillShown = true }
            AccessibilityNotification.Announcement("Connected to \(host)").post()
        }
    }
}

// MARK: - Shared pieces

/// The full-width call to action pinned to the bottom of each step, above the keyboard.
private struct OnboardingPrimaryButton: View {

    let title: String
    let id: String
    var busy = false
    let action: () -> Void

    @AppStorage(AppearanceKey.accent) private var accent = Accent.mono

    var body: some View {
        Button(action: action) {
            ZStack {
                Text(title).opacity(busy ? 0 : 1)
                if busy { ProgressView().tint(accent.onColor) }
            }
            .font(.headline)
            .foregroundStyle(accent.onColor)
            .frame(maxWidth: .infinity)
            .contentTransition(.opacity)
        }
        .buttonStyle(.glassProminent)
        .controlSize(.large)
        .accessibilityLabel(busy ? "Connecting" : title)
        .accessibilityIdentifier(id)
    }
}

private extension View {
    /// The shared content column: at most 440 pt wide, centred, 24 pt from the edges.
    func onboardingColumn() -> some View {
        frame(maxWidth: 440).padding(.horizontal, 24).frame(maxWidth: .infinity)
    }
}

#Preview {
    OnboardingView { _ in }
}
