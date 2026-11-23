#if DEBUG && targetEnvironment(simulator)
import SwiftUI

struct AskHermesUITestProbe: View {
    private let prompt: String
    private let key: String?
    private let cancellation: String?
    private let previousSubmits: Int
    @State private var result: HermesAskResult?
    @State private var didCancel = false

    init?(environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard let prompt = environment["ORBIT_TEST_ASK_PROMPT"],
              let base = HermesClient.shared.baseURL, base.host() == "127.0.0.1", base.port == 18765,
              base.path().hasPrefix("/shortcut-") else { return nil }
        self.prompt = prompt
        key = environment["ORBIT_TEST_ASK_KEY"]
        cancellation = environment["ORBIT_TEST_ASK_CANCEL"]
        previousSubmits = Int(environment["ORBIT_TEST_ASK_PREVIOUS_SUBMITS"] ?? "") ?? 0
    }

    var body: some View {
        VStack {
            if let result {
                Text(verbatim: result.status.rawValue).accessibilityIdentifier("test.ask.status")
                Text(verbatim: result.reply.isEmpty ? "(empty)" : result.reply)
                    .accessibilityIdentifier("test.ask.reply")
            } else if didCancel {
                Text("cancelled").accessibilityIdentifier("test.ask.status")
                Text("(empty)").accessibilityIdentifier("test.ask.reply")
            } else {
                ProgressView()
            }
        }
        .task {
            let intent = AskHermesIntent()
            intent.prompt = prompt
            intent.destination = .newChat
            if let key {
                intent.destination = .existingChat
                let client = HermesClient.shared
                intent.chat = HermesChatEntity(id: client.shortcutScope + "|" + key, title: "Test chat")
            }
            let task = Task {
                try await intent.run(connecting: {}, waiting: {})
            }
            if cancellation == "beforeSend" { task.cancel() }
            let cancel = Task {
                switch cancellation {
                case "afterSend":
                    guard let base = HermesClient.shared.baseURL else { return }
                    let url = base.appendingPathComponent("fixture/state")
                    while !Task.isCancelled {
                        let response = try? await URLSession.shared.data(from: url)
                        if let data = response?.0, (JSON.decode(data)?["prompts"].int ?? 0) > previousSubmits {
                            task.cancel()
                            break
                        }
                        try? await Task.sleep(for: .milliseconds(50))
                    }
                default: break
                }
            }
            defer { cancel.cancel() }
            do { result = HermesAskResult(try await task.value) }
            catch is CancellationError { didCancel = true }
            catch { result = HermesAskResult(HermesAskOutcome(.failed)) }
        }
    }
}
#endif
