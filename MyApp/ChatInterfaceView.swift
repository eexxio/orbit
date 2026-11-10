
import SwiftUI

struct ChatInterfaceView: View {

    @State private var messages: [ChatMessage] = [
        ChatMessage(
            text: "Can you explain SwiftUI?",
            isUser: true
        ),
        ChatMessage(
            text: """
            Absolutely! **SwiftUI** is Apple's modern framework for building apps across iOS, macOS, watchOS, and more.

            ### How it works

            SwiftUI uses a declarative syntax. You describe what your interface should look like, and the framework handles rendering it.

            For example:

            ```swift
            Text("Hello, world!")
                .font(.title)
                .foregroundStyle(.blue)
            ```

            **Some key concepts:**

            - `View` – Building blocks of your interface.
            - `@State` – Manages local view state.
            - `VStack` – Arranges views vertically.
            - `NavigationStack` – Handles navigation.

            It's a great way to build modern Apple applications!
            """,
            isUser: false
        ),
        ChatMessage(
            text: "What is the difference between VStack and HStack?",
            isUser: true
        ),
        ChatMessage(
            text: """
            Great question! Both `VStack` and `HStack` are layout containers in SwiftUI.

            ### VStack
            A `VStack` arranges views vertically, from top to bottom.

            ```swift
            VStack {
                Text("First")
                Text("Second")
                Text("Third")
            }
            ```

            ### HStack
            An `HStack` arranges views horizontally, from left to right.

            ```swift
            HStack {
                Text("First")
                Text("Second")
                Text("Third")
            }
            ```

            **In short:** Use `VStack` for vertical layouts and `HStack` for horizontal layouts.
            """,
            isUser: false
        ),
        ChatMessage(
            text: "Can I combine them to create more complex layouts?",
            isUser: true
        ),
        ChatMessage(
            text: """
            Absolutely! You can nest stacks inside one another to create almost any layout.

            For example:

            ```swift
            VStack(alignment: .leading, spacing: 16) {
                Text("My Profile")
                    .font(.title)

                HStack {
                    Image(systemName: "person.circle.fill")
                        .font(.largeTitle)

                    VStack(alignment: .leading) {
                        Text("John Appleseed")
                            .font(.headline)

                        Text("iOS Developer")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding()
            ```

            Here, the outer `VStack` arranges content vertically, while the inner `HStack` places the profile image and user information side by side.

            Nesting stacks is one of the most useful techniques in SwiftUI!
            """,
            isUser: false
        ),
        ChatMessage(
            text: "How does @State work?",
            isUser: true
        ),
        ChatMessage(
            text: """
            `@State` is a property wrapper that allows a SwiftUI view to store and manage its own data.

            When the state changes, SwiftUI automatically updates the parts of the interface that depend on it.

            ### Example

            ```swift
            struct CounterView: View {
                @State private var count = 0

                var body: some View {
                    VStack(spacing: 20) {
                        Text("Count: \\(count)")
                            .font(.largeTitle)

                        Button("Increase") {
                            count += 1
                        }
                    }
                    .padding()
                }
            }
            ```

            Every time you press the button, the count increases and the displayed text updates automatically.

            **Remember:** Use `@State` for data owned by a view.
            """,
            isUser: false
        ),
        ChatMessage(
            text: "What about animations? Can SwiftUI animate these changes?",
            isUser: true
        ),
        ChatMessage(
            text: """
            Yes! SwiftUI makes animations very easy.

            You can use `withAnimation` to animate state changes.

            ```swift
            struct AnimationView: View {
                @State private var isExpanded = false

                var body: some View {
                    VStack {
                        RoundedRectangle(cornerRadius: 20)
                            .fill(.blue)
                            .frame(
                                width: isExpanded ? 250 : 120,
                                height: 120
                            )

                        Button("Toggle Animation") {
                            withAnimation(.spring(duration: 0.5)) {
                                isExpanded.toggle()
                            }
                        }
                    }
                }
            }
            ```

            SwiftUI automatically animates the size change using a spring animation.

            You can also animate opacity, rotation, position, scale, and much more!
            """,
            isUser: false
        ),
        ChatMessage(
            text: "That sounds great! What should I learn next?",
            isUser: true
        ),
        ChatMessage(
            text: """
            You're making great progress! Here is a learning path I recommend:

            ### Your SwiftUI learning roadmap

            1. **Layouts** – Learn `VStack`, `HStack`, `ZStack`, and `LazyVGrid`.
            2. **State management** – Understand `@State`, `@Binding`, and `@Observable`.
            3. **Navigation** – Explore `NavigationStack` and navigation destinations.
            4. **Lists** – Build dynamic lists using `List` and `ForEach`.
            5. **Animations** – Practice transitions and implicit animations.
            6. **Networking** – Fetch data from APIs using `URLSession` and async/await.
            7. **Persistence** – Learn SwiftData for storing application data.

            ### My recommendation

            Start by building a simple to-do list application. It will help you practice layouts, state management, lists, and user interactions.

            Once you're comfortable with that, try building a weather application!

            Happy coding! 🚀
            """,
            isUser: false
        )
    ]


    @State private var draft = ""
    @State private var isGenerating = false

    @FocusState private var composerIsFocused: Bool

    var body: some View {
        NavigationStack {
            Group {
                if messages.isEmpty {
                    emptyState
                } else {
                    conversation
                }
            }
            .background(Color(uiColor: .systemBackground))
            .safeAreaInset(edge: .bottom, spacing: 0) {
                composer
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 22) {
            Spacer()

            Image(systemName: "sparkle")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 68, height: 68)
                .background(
                    Color(uiColor: .secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 22)
                )

            VStack(spacing: 7) {
                Text("What can I help with?")
                    .font(.title2.weight(.semibold))

                Text("Ask a question, explore an idea, or get something done.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 10) {
                suggestion("Explain something to me")
                suggestion("Help me write or brainstorm")
                suggestion("Plan a project")
            }
            .padding(.horizontal, 28)

            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding()
    }

    // MARK: - Conversation

    private var conversation: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                ForEach(messages) { message in
                    messageRow(message)
                }

                if isGenerating {
                    HStack(spacing: 10) {
                        ProgressView()

                        Text("Thinking…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.leading, 4)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)
            .padding(.bottom, 16)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    // MARK: - Message Row

    @ViewBuilder
    private func messageRow(_ message: ChatMessage) -> some View {
        if message.isUser {
            HStack {
                Spacer(minLength: 48)

                Text(message.text)
                    .padding(.horizontal, 15)
                    .padding(.vertical, 11)
                    .foregroundStyle(.white)
                    .background(
                        Color.black,
                        in: RoundedRectangle(cornerRadius: 20)
                    )
            }
        } else {
            VStack(alignment: .leading, spacing: 12) {
                Text(.init(message.text))
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 20) {
                    Button {
                        UIPasteboard.general.string = message.text
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Composer

    private var composer: some View {
        HStack {
            TextField("Ask anything", text: $draft)
                .focused($composerIsFocused)
                .padding()
                .submitLabel(.send)
                .onSubmit {
                    sendMessage()
                }

            Button {
                sendMessage()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title)
                    .foregroundStyle(.primary)
            }
            .disabled(
                draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
        }
        .padding(.horizontal)
        .glassEffect(.regular.interactive(), in: Capsule())
        .padding()
    }

    // MARK: - Suggestions

    private func suggestion(_ title: String) -> some View {
        Button {
            draft = title
            composerIsFocused = true
        } label: {
            HStack {
                Text(title)

                Spacer()

                Image(systemName: "arrow.up.left")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .font(.subheadline)
            .foregroundStyle(.primary)
            .padding(14)
            .background(
                Color(uiColor: .secondarySystemBackground),
                in: RoundedRectangle(cornerRadius: 14)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Send Message

    private func sendMessage() {
        let text = draft.trimmingCharacters(
            in: .whitespacesAndNewlines
        )

        guard !text.isEmpty else { return }

        messages.append(
            ChatMessage(text: text, isUser: true)
        )

        draft = ""
        composerIsFocused = false

        // Connect your AI service here and append its response to messages.
    }
}

// MARK: - Chat Message Model

private struct ChatMessage: Identifiable {
    let id = UUID()
    let text: String
    let isUser: Bool
}

#Preview {
    ChatInterfaceView()
}
