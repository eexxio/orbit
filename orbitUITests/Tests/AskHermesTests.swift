import XCTest

final class AskHermesTests: XCTestCase {
    private struct FixtureState: Decodable {
        let connections: Int
        let prompts: Int
        let interrupts: Int
        let closed: Int
        let resumed: [String]
    }

    private let venus = "Venus takes about 225 Earth days to orbit the Sun."

    @MainActor
    func testNewAndExactExistingChatReturnFullReply() async throws {
        try await run("shortcut-new", prompt: "  Ask about Venus  ", status: "completed", reply: venus, submits: 1)
        try await run("shortcut-existing", prompt: "Ask about Venus", key: "fixture-b", status: "completed",
                      reply: venus, submits: 1, resumes: ["fixture-b"])
    }

    @MainActor
    func testValidationStaleChatAndSignInDoNotSend() async throws {
        try await run("shortcut-invalid", prompt: " \n ", status: "invalidPrompt", submits: 0)
        try await run("shortcut-invalid", prompt: String(repeating: "a", count: 8_001),
                      status: "invalidPrompt", submits: 0)
        try await run("shortcut-stale", prompt: "Ask about Venus", key: "fixture-deleted",
                      status: "chatUnavailable", submits: 0)
        try await run("shortcut-auth", prompt: "Ask about Venus", status: "signInRequired", submits: 0)
    }

    @MainActor
    func testBusyAndQueuedNeverAttributeForeignCompletion() async throws {
        try await run("shortcut-busy", prompt: "Ask about Venus", key: "fixture-a",
                      status: "busy", submits: 0, resumes: ["fixture-a"])
        try await run("shortcut-legacy-queued", prompt: "Ask about Venus", status: "queued", submits: 1)
        try await run("shortcut-legacy", prompt: "Ask about Venus", status: "completed", reply: venus, submits: 1)
    }

    @MainActor
    func testOnlyCompleteTextIsReturned() async throws {
        try await run("shortcut-output", prompt: "Fail", status: "failed", submits: 1)
        try await run("shortcut-output", prompt: "No text", status: "noText", submits: 1)
        try await run("shortcut-output", prompt: "Oversize", status: "replyTooLarge", submits: 1)
        try await run("shortcut-approval", prompt: "Approval", status: "needsInput", submits: 1)
    }

    @MainActor
    func testTimeoutAndDisconnectDoNotResubmitOrInterrupt() async throws {
        try await run("shortcut-timeout", prompt: "Wait", status: "timedOut", submits: 1)
        try await run("shortcut-no-receipt", prompt: "Ask about Venus", status: "deliveryUnknown", submits: 1)
        try await run("shortcut-disconnect", prompt: "Ask about Venus", status: "deliveryUnknown", submits: 1)
    }

    @MainActor
    func testCancellationBeforeAndAfterSendReleasesTheSocketWithoutInterrupting() async throws {
        try await run("shortcut-cancel-before", prompt: "Wait", status: "cancelled",
                      submits: 0, cancellation: "beforeSend")
        try await run("shortcut-cancel-after", prompt: "Wait", status: "cancelled",
                      submits: 1, cancellation: "afterSend")
    }

    @MainActor
    private func run(_ fixture: String, prompt: String, key: String? = nil, status: String,
                     reply: String = "", submits: Int, resumes: [String] = [], cancellation: String? = nil) async throws {
        continueAfterFailure = false
        let address = "http://127.0.0.1:18765/\(fixture)"
        let before = try await state(address)
        let app = XCUIApplication()
        app.launchArguments = ["-hermes.address", address, "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment = ["ORBIT_TEST_ASK_PROMPT": prompt]
        app.launchEnvironment["ORBIT_TEST_ASK_PREVIOUS_SUBMITS"] = String(before.prompts)
        if let key { app.launchEnvironment["ORBIT_TEST_ASK_KEY"] = key }
        if let cancellation { app.launchEnvironment["ORBIT_TEST_ASK_CANCEL"] = cancellation }
        app.launch()
        defer { app.terminate() }
        let actual = app.staticTexts["test.ask.status"]
        XCTAssertTrue(actual.waitForExistence(timeout: 30))
        XCTAssertEqual(actual.label, status)
        XCTAssertEqual(app.staticTexts["test.ask.reply"].label, reply.isEmpty ? "(empty)" : reply)
        var after = try await state(address)
        for _ in 0..<20 where after.closed < after.connections {
            try await Task.sleep(for: .milliseconds(100))
            after = try await state(address)
        }
        XCTAssertEqual(after.prompts - before.prompts, submits)
        XCTAssertEqual(after.interrupts, before.interrupts)
        XCTAssertEqual(after.closed - before.closed, after.connections - before.connections)
        XCTAssertEqual(Array(after.resumed.dropFirst(before.resumed.count)), resumes)
    }

    private func state(_ address: String) async throws -> FixtureState {
        let (data, _) = try await URLSession.shared.data(from: URL(string: "\(address)/fixture/state")!)
        return try JSONDecoder().decode(FixtureState.self, from: data)
    }
}
