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
    func testCodeBlockPolish() async throws {
        let app = launchChat()
        send("Show code blocks", in: app)
        let copies = app.buttons.matching(identifier: "chat.codeblock.copy")
        XCTAssertTrue(copies.firstMatch.waitForExistence(timeout: 10))
        app.swipeDown()
        let swiftCopy = copies.matching(NSPredicate(format: "label == %@", "Copy swift code")).firstMatch
        for _ in 0..<4 where !swiftCopy.isHittable { app.swipeDown() }
        XCTAssertTrue(swiftCopy.isHittable)
        XCTAssertTrue(app.staticTexts.matching(identifier: "chat.codeblock.language")
            .matching(NSPredicate(format: "label == %@", "swift")).firstMatch.exists)
        screenshot("codeblock-swift-unlabeled")
        swiftCopy.tap()
        screenshot("codeblock-copied")
        swiftCopy.tap()
        XCTAssertEqual(swiftCopy.value as? String, "Copied")
        XCTAssertTrue(copies.matching(NSPredicate(format: "label == %@", "Copy code")).firstMatch.exists)
        XCTAssertEqual(app.staticTexts.matching(identifier: "chat.codeblock.language").count, 2)
        let reset = NSPredicate(format: "value != %@", "Copied")
        await fulfillment(of: [expectation(for: reset, evaluatedWith: swiftCopy)], timeout: 4)
        app.swipeUp()
        screenshot("codeblock-long-line-unscrolled-table")
        let codeBody = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "json code block")).firstMatch
        XCTAssertTrue(codeBody.isHittable)
        codeBody.swipeLeft()
        screenshot("codeblock-long-line-scrolled")
        let table = app.scrollViews.allElementsBoundByIndex.last { $0.frame.height < 100 && $0.frame.width > 300 }
        XCTAssertNotNil(table)
        table?.swipeLeft()
        screenshot("codeblock-wide-table-scrolled")
    }

    @MainActor
    func testInterruptedCodeRemainsCopyable() async throws {
        let app = launchChat()
        send("Interrupt code", in: app)
        let copy = app.buttons["chat.codeblock.copy"]
        XCTAssertTrue(copy.waitForExistence(timeout: 10))
        copy.tap()
        XCTAssertEqual(copy.value as? String, "Copied")
        try await advance("code-interrupted", to: "end")
        XCTAssertTrue(app.staticTexts["chat.reply.interrupted"].waitForExistence(timeout: 10))
        XCTAssertTrue(copy.isEnabled)
        screenshot("codeblock-interrupted")
    }

    @MainActor
    func testReplyStreamsThenCompletes() async throws {
        let app = launchChat()
        send("Complete the reply", in: app)

        let waiting = app.staticTexts["chat.reply.waiting"]
        XCTAssertTrue(waiting.waitForExistence(timeout: 10))
        XCTAssertTrue(button("chat.stop", in: app).isEnabled)
        XCTAssertFalse(button("chat.send", in: app).exists)
        screenshot("chat-waiting")
        try await advance("complete", to: "delta")

        let streaming = app.staticTexts["chat.reply.streaming"]
        XCTAssertTrue(streaming.waitForExistence(timeout: 10))
        XCTAssertTrue(button("chat.stop", in: app).isEnabled)
        XCTAssertFalse(button("chat.send", in: app).exists)
        XCTAssertTrue(reply(partial, in: app).exists)
        XCTAssertFalse(waiting.exists)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier IN %@", ["chat.reply.copy", "chat.reply.completed"])).firstMatch.exists)
        XCTAssertFalse(button("chat.reply.completed", in: app).exists)
        screenshot("chat-streaming")
        try await advance("complete", to: "end")

        XCTAssertTrue(reply(partial + " and the ending.", in: app).waitForExistence(timeout: 10))
        XCTAssertFalse(reply(partial, in: app).exists)
        XCTAssertTrue(streaming.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier IN %@", ["chat.reply.copy", "chat.reply.completed"])).firstMatch.exists)
        XCTAssertTrue(button("chat.reply.completed", in: app).exists)
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
        XCTAssertFalse(app.staticTexts["chat.reply.stopped"].exists)
        XCTAssertTrue(reply(partial, in: app).exists)
        XCTAssertFalse(streaming.exists)
        XCTAssertEqual(tool.value as? String, "Tool result not received")
        XCTAssertFalse(button("chat.reply.completed", in: app).exists)
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
        let sendButton = button("chat.send", in: app)
        XCTAssertFalse(sendButton.exists)
        XCTAssertTrue(button("chat.stop", in: app).isEnabled)
        try await advance("failure", to: "end")

        XCTAssertTrue(app.staticTexts["chat.reply.failed"].waitForExistence(timeout: 10))
        XCTAssertFalse(streaming.exists)
        XCTAssertTrue(reply(partial, in: app).exists)
        XCTAssertEqual(draft.value as? String, "My next message")
        XCTAssertTrue(sendButton.isEnabled)
        screenshot("chat-failed")
    }

    @MainActor
    func testStopKeepsPartialReplyAndDraft() async throws {
        try await stopReply("Stop the reply", scenario: "stop")
    }

    @MainActor
    func testStopWithoutFinalEvent() async throws {
        try await stopReply("Stop without final", scenario: "stop-no-final")
    }

    @MainActor
    func testStopWithInterruptError() async throws {
        try await stopReply("Stop with error", scenario: "stop-error")
    }

    @MainActor
    func testStopWhenHostIgnoresInterrupt() async throws {
        try await stopReply("Ignore the stop", scenario: "stop-ignore")
    }

    @MainActor
    func testStopWhileWaiting() async throws {
        let app = launchChat()
        send("Stop while waiting", in: app)
        XCTAssertTrue(app.staticTexts["chat.reply.waiting"].waitForExistence(timeout: 10))
        let stop = button("chat.stop", in: app)
        XCTAssertTrue(stop.waitForExistence(timeout: 10))
        XCTAssertTrue(stop.isEnabled)
        XCTAssertFalse(button("chat.send", in: app).exists)
        XCTAssertEqual(app.keyboards.count, 0)
        let width = composer(in: app).frame.width
        XCTAssertLessThan(width, 240)
        stop.tap()
        XCTAssertTrue(app.staticTexts["chat.reply.stopped"].waitForExistence(timeout: 10))
        try await advance("stop-waiting", to: "interrupted")
        XCTAssertFalse(app.staticTexts["chat.reply.waiting"].exists)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier IN %@", ["chat.reply.copy", "chat.reply.completed"])).firstMatch.exists)
        XCTAssertFalse(reply(partial, in: app).exists)
        XCTAssertEqual(app.keyboards.count, 0)
        XCTAssertEqual(composer(in: app).frame.width, width, accuracy: 1)
        XCTAssertFalse(button("chat.send", in: app).isEnabled)
        screenshot("stop-waiting")
        send("Send after reconnecting", in: app)
        XCTAssertTrue(reply("The next reply arrived.", in: app).waitForExistence(timeout: 10))
    }

    @MainActor
    private func stopReply(_ prompt: String, scenario: String) async throws {
        let app = launchChat()
        send(prompt, in: app)
        try await advance(scenario, to: "delta")
        XCTAssertTrue(app.staticTexts["chat.reply.streaming"].waitForExistence(timeout: 10))
        XCTAssertTrue(button("chat.stop", in: app).isEnabled)
        XCTAssertFalse(button("chat.send", in: app).exists)
        let before = try await fixtureState()
        let field = composer(in: app)
        field.tap()
        field.typeText("Send the next reply")
        XCTAssertTrue(button("chat.stop", in: app).isEnabled)
        XCTAssertEqual(button("chat.stop", in: app).label, "Stop reply")
        screenshot("stop-streaming-\(scenario)")
        button("chat.stop", in: app).tap()
        XCTAssertTrue(app.staticTexts["chat.reply.stopped"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["chat.reply.interrupted"].exists)
        XCTAssertFalse(app.staticTexts["chat.reply.failed"].exists)
        XCTAssertTrue(reply(partial, in: app).exists)
        XCTAssertFalse(app.staticTexts["chat.reply.streaming"].exists)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier IN %@", ["chat.reply.copy", "chat.reply.completed"])).firstMatch.exists)
        XCTAssertFalse(button("chat.reply.completed", in: app).exists)
        XCTAssertEqual(field.value as? String, "Send the next reply")
        XCTAssertTrue(button("chat.send", in: app).isEnabled)
        let tool = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "get_weather")).firstMatch
        XCTAssertEqual(tool.value as? String, "Tool result not received")
        if scenario == "stop" { screenshot("stop-stopped-\(scenario)") }
        button("chat.send", in: app).tap()
        try await advance(scenario, to: "interrupted")
        try await advance("next", to: "delta")
        XCTAssertTrue(app.staticTexts["chat.reply.streaming"].waitForExistence(timeout: 10))
        XCTAssertTrue(reply("The next reply", in: app).exists)
        try await advance("next", to: "end")
        XCTAssertTrue(reply("The next reply arrived.", in: app).waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label == %@", partial)).count, 1)
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label == %@", "The next reply arrived.")).count, 1)
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "OLD TURN MUST NOT APPEAR")).firstMatch.exists)
        XCTAssertFalse(reply("Late final", in: app).exists)
        let after = try await fixtureState()
        XCTAssertEqual(after["prompts"], before["prompts"]! + 1)
        let reconnects = ["stop-error", "stop-ignore"].contains(scenario) ? 1 : 0
        XCTAssertEqual(after["connections"], before["connections"]! + reconnects)
    }

    @MainActor
    private func launchChat() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-hermes.address", address, "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let newChat = button("chats.new", in: app)
        XCTAssertTrue(newChat.waitForExistence(timeout: 10))
        newChat.tap()
        return app
    }

    @MainActor
    private func button(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier == %@", identifier)).firstMatch
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
        let button = button("chat.send", in: app)
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

    private func fixtureState() async throws -> [String: Int] {
        let (data, _) = try await URLSession.shared.data(from: URL(string: "\(address)/fixture/state")!)
        return try JSONDecoder().decode([String: Int].self, from: data)
    }

    @MainActor
    private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
