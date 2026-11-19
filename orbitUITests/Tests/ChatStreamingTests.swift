import XCTest

final class ChatStreamingTests: XCTestCase {
    private let fixtureID = UUID()
    private var address: String { "http://127.0.0.1:18765/\(fixtureID)" }
    private let partial = "Here is the first part"

    @MainActor
    func testNewChatAfterCompletedReplyIsBlank() async throws {
        try await checkNewChatIsBlank(prompt: "Complete the reply", scenario: "complete", status: "completed")
    }

    @MainActor
    func testNewChatAfterInterruptedReplyIsBlank() async throws {
        try await checkNewChatIsBlank(prompt: "Close the connection", scenario: "disconnect", status: "interrupted")
    }

    @MainActor
    func testNewChatAfterFailedReplyIsBlank() async throws {
        try await checkNewChatIsBlank(prompt: "Fail the reply", scenario: "failure", status: "failed")
    }

    @MainActor
    private func checkNewChatIsBlank(prompt: String, scenario: String, status: String) async throws {
        let app = launchChat()
        XCTAssertTrue(app.staticTexts["New chat"].waitForExistence(timeout: 5))
        send(prompt, in: app)
        try await advance(scenario, to: "delta")
        XCTAssertTrue(app.staticTexts["chat.reply.streaming"].waitForExistence(timeout: 10))
        try await advance(scenario, to: "end")
        XCTAssertTrue(app.descendants(matching: .any)["chat.reply.\(status)"].firstMatch.waitForExistence(timeout: 10))
        app.navigationBars.buttons["Chats"].tap()
        let newChat = app.buttons["chats.new"]
        XCTAssertTrue(newChat.waitForExistence(timeout: 5))
        newChat.tap()
        XCTAssertTrue(composer(in: app).waitForExistence(timeout: 5))
        screenshot("new-chat-after-\(status)")
        XCTAssertTrue(app.staticTexts["New chat"].waitForExistence(timeout: 5))
        XCTAssertFalse(reply(prompt, in: app).exists)
        XCTAssertFalse(reply(partial, in: app).exists)
        XCTAssertFalse(reply(partial + " and the ending.", in: app).exists)
        XCTAssertEqual(composer(in: app).value as? String, "")
        XCTAssertFalse(app.buttons["chat.send"].isEnabled)
    }

    @MainActor
    func testReplyStreamsThenCompletes() async throws {
        let app = launchChat()
        send("Complete the reply", in: app)

        let waiting = app.staticTexts["chat.reply.waiting"]
        XCTAssertTrue(waiting.waitForExistence(timeout: 10))
        screenshot("chat-waiting")
        try await advance("complete", to: "delta")

        let streaming = app.staticTexts["chat.reply.streaming"]
        XCTAssertTrue(streaming.waitForExistence(timeout: 10))
        XCTAssertTrue(reply(partial, in: app).exists)
        XCTAssertFalse(waiting.exists)
        XCTAssertFalse(app.buttons["Copy reply"].exists)
        XCTAssertFalse(app.buttons["chat.reply.completed"].exists)
        screenshot("chat-streaming")
        try await advance("complete", to: "end")

        XCTAssertTrue(reply(partial + " and the ending.", in: app).waitForExistence(timeout: 10))
        XCTAssertFalse(reply(partial, in: app).exists)
        XCTAssertTrue(streaming.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Copy reply"].exists)
        XCTAssertTrue(app.buttons["chat.reply.completed"].exists)
        screenshot("chat-completed")
    }

    @MainActor
    func testSocketCloseKeepsPartialReplyAndAllowsAnotherSend() async throws {
        let app = launchChat()
        send("Close the connection", in: app)
        try await advance("disconnect", to: "delta")

        let streaming = app.staticTexts["chat.reply.streaming"]
        XCTAssertTrue(streaming.waitForExistence(timeout: 10))
        let tool = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "get_weather")).firstMatch
        XCTAssertTrue(tool.waitForExistence(timeout: 5))
        XCTAssertEqual(tool.value as? String, "Running")
        try await advance("disconnect", to: "end")

        let interrupted = app.staticTexts["chat.reply.interrupted"]
        XCTAssertTrue(interrupted.waitForExistence(timeout: 10))
        XCTAssertTrue(reply(partial, in: app).exists)
        XCTAssertFalse(streaming.exists)
        XCTAssertEqual(tool.value as? String, "Tool result not received")
        XCTAssertFalse(app.buttons["chat.reply.completed"].exists)
        screenshot("chat-interrupted")

        send("Send after reconnecting", in: app)
        XCTAssertTrue(reply("The next reply arrived.", in: app).waitForExistence(timeout: 10))
        XCTAssertFalse(interrupted.exists)
    }

    @MainActor
    func testServerFailureReenablesSendWithoutLosingDraft() async throws {
        let app = launchChat()
        send("Fail the reply", in: app)
        try await advance("failure", to: "delta")
        let streaming = app.staticTexts["chat.reply.streaming"]
        XCTAssertTrue(streaming.waitForExistence(timeout: 10))

        let draft = composer(in: app)
        draft.tap()
        draft.typeText("My next message")
        let sendButton = app.buttons["chat.send"]
        XCTAssertFalse(sendButton.isEnabled)
        try await advance("failure", to: "end")

        XCTAssertTrue(app.staticTexts["chat.reply.failed"].waitForExistence(timeout: 10))
        XCTAssertFalse(streaming.exists)
        XCTAssertTrue(reply(partial, in: app).exists)
        XCTAssertEqual(draft.value as? String, "My next message")
        XCTAssertTrue(sendButton.isEnabled)
        screenshot("chat-failed")
    }

    @MainActor
    private func launchChat() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-hermes.address", address, "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let newChat = app.buttons["chats.new"]
        XCTAssertTrue(newChat.waitForExistence(timeout: 10))
        newChat.tap()
        return app
    }

    @MainActor
    private func composer(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["chat.composer"].firstMatch
    }

    @MainActor
    private func send(_ text: String, in app: XCUIApplication) {
        let field = composer(in: app)
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText(text)
        let button = app.buttons["chat.send"]
        XCTAssertEqual(field.value as? String, text)
        XCTAssertTrue(button.isEnabled)
        button.tap()
        let sent = reply(text, in: app)
        if !sent.waitForExistence(timeout: 2), field.value as? String == text, button.isEnabled {
            button.tap()
        }
        XCTAssertTrue(sent.waitForExistence(timeout: 5))
    }

    @MainActor
    private func reply(_ text: String, in app: XCUIApplication) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label == %@", text)).firstMatch
    }

    private func advance(_ scenario: String, to phase: String) async throws {
        var request = URLRequest(url: URL(string: "\(address)/fixture/\(scenario)/\(phase)")!, timeoutInterval: 5)
        request.httpMethod = "POST"
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 204)
    }

    @MainActor
    private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
