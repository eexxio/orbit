import XCTest

final class MessageActionsTests: XCTestCase {
    private let fixtureID = UUID()
    private var address: String { "http://127.0.0.1:18765/\(fixtureID)" }

    override func tearDown() async throws {
        try await configure("rewind")
        try await super.tearDown()
    }

    @MainActor
    func testCopyAndSelectText() async throws {
        let app = try await launchChat()
        send("Read actions", in: app)
        waitForReply("Reply 1: Read actions", in: app)
        openReplyMenu(in: app)
        screenshot("reply-context-menu")
        let copy = app.buttons["message.action.copy"]
        XCTAssertTrue(copy.exists)
        copy.tap()
        openReplyMenu(in: app)
        app.buttons["message.action.select"].tap()
        XCTAssertTrue(app.navigationBars["Select Text"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textViews.firstMatch.exists)
        screenshot("select-text-sheet")
        app.buttons["Done"].tap()
    }

    @MainActor
    func testRegenerateReplacesReply() async throws {
        let app = try await launchChat()
        send("Replace reply", in: app)
        waitForReply("Reply 1: Replace reply", in: app)
        openReplyMenu(in: app)
        app.buttons["message.action.regenerate"].tap()
        waitForReply("Reply 2: Replace reply", in: app)
        XCTAssertFalse(app.staticTexts["Reply 1: Replace reply"].exists)
        try await assertHistory(["Replace reply", "Reply 2: Replace reply"])
    }

    @MainActor
    func testEditReplacesLastTurn() async throws {
        let app = try await launchChat()
        send("Original prompt", in: app)
        waitForReply("Reply 1: Original prompt", in: app)
        openUserMenu(in: app)
        screenshot("user-context-menu")
        app.buttons["message.action.edit"].tap()
        XCTAssertTrue(app.otherElements["chat.edit.banner"].waitForExistence(timeout: 5)
                      || app.staticTexts["Editing message"].exists)
        screenshot("edit-mode")
        replaceComposer(with: "Edited prompt", in: app)
        XCTAssertEqual(app.buttons["chat.send"].label, "Send edit")
        app.buttons["chat.send"].tap()
        waitForReply("Reply 1: Edited prompt", in: app)
        XCTAssertFalse(app.staticTexts["Reply 1: Original prompt"].exists)
        try await assertHistory(["Edited prompt", "Reply 1: Edited prompt"])
    }

    @MainActor
    func testCancelEditRestoresDraft() async throws {
        let app = try await launchChat()
        send("Keep this turn", in: app)
        waitForReply("Reply 1: Keep this turn", in: app)
        composer(in: app).tap()
        composer(in: app).typeText("Unsent draft")
        openUserMenu(in: app)
        app.buttons["message.action.edit"].tap()
        XCTAssertEqual(composer(in: app).value as? String, "Keep this turn")
        replaceComposer(with: "", in: app)
        app.buttons["chat.edit.cancel"].tap()
        XCTAssertEqual(composer(in: app).value as? String, "Unsent draft")
        try await assertHistory(["Keep this turn", "Reply 1: Keep this turn"])
    }

    @MainActor
    func testFailedRewindKeepsReplyAndRetrySucceeds() async throws {
        let app = try await launchChat(mode: "fail-undo")
        send("Keep old reply", in: app)
        waitForReply("Reply 1: Keep old reply", in: app)
        openReplyMenu(in: app)
        app.buttons["message.action.regenerate"].tap()
        XCTAssertTrue(app.staticTexts["chat.reply.failed"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Reply 1: Keep old reply"].exists)
        XCTAssertTrue(app.staticTexts["Couldn't regenerate: The fixture refused to rewind."].exists)
        screenshot("failed-rewind-retry")
        try await assertHistory(["Keep old reply", "Reply 1: Keep old reply"])
        app.buttons["chat.reply.retry"].tap()
        waitForReply("Reply 2: Keep old reply", in: app)
        try await assertHistory(["Keep old reply", "Reply 2: Keep old reply"])
    }

    @MainActor
    func testInlineRetryWithoutAssistantText() async throws {
        let app = try await launchChat()
        send("Action failure", in: app)
        XCTAssertTrue(app.staticTexts["chat.reply.failed"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["chat.message.reply"].exists)
        screenshot("failed-reply-retry")
        app.buttons["chat.reply.retry"].tap()
        waitForReply("Reply 2: Action failure", in: app)
        try await assertHistory(["Action failure", "Reply 2: Action failure"])
    }

    @MainActor
    func testFallbackEditAppendsAndRetryAppends() async throws {
        let app = try await launchChat(mode: "fallback")
        send("Fallback prompt", in: app)
        waitForReply("Reply 1: Fallback prompt", in: app)
        openReplyMenu(in: app)
        XCTAssertFalse(app.buttons["message.action.regenerate"].exists)
        app.buttons["message.action.copy"].tap()
        openUserMenu(in: app)
        XCTAssertEqual(app.buttons["message.action.edit"].label, "Edit as New Message")
        screenshot("fallback-user-menu")
        app.buttons["message.action.edit"].tap()
        XCTAssertTrue(app.staticTexts["New message from edit"].exists)
        replaceComposer(with: "Action failure", in: app)
        app.buttons["chat.send"].tap()
        XCTAssertTrue(app.staticTexts["chat.reply.failed"].waitForExistence(timeout: 10))
        app.buttons["chat.reply.retry"].tap()
        waitForReply("Reply 2: Action failure", in: app)
        try await assertHistory(["Fallback prompt", "Reply 1: Fallback prompt", "Action failure", "Action failure", "Reply 2: Action failure"])
    }

    @MainActor
    func testToolsRequireConfirmation() async throws {
        let app = try await launchChat()
        send("Tools reply", in: app)
        waitForReply("Reply 1: Tools reply", in: app)
        XCTAssertTrue(app.staticTexts["lookup"].exists || app.otherElements["lookup"].exists)
        openReplyMenu(in: app)
        app.buttons["message.action.regenerate"].tap()
        XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 5))
        screenshot("regenerate-confirmation")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "This reply ran 1 tool(s).")).firstMatch.exists)
        app.buttons["Cancel"].tap()
        try await assertHistory(["Tools reply", "Reply 1: Tools reply"])
    }

    @MainActor
    private func launchChat(mode: String = "rewind") async throws -> XCUIApplication {
        continueAfterFailure = false
        try await configure(mode)
        let app = XCUIApplication()
        app.launchArguments = ["-hermes.address", address, "-hermes.theme", "light", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.buttons["chats.new"].waitForExistence(timeout: 10))
        app.buttons["chats.new"].tap()
        return app
    }

    private func configure(_ mode: String) async throws {
        var request = URLRequest(url: URL(string: "\(address)/fixture/reset/\(mode)")!)
        request.httpMethod = "POST"
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 204)
    }

    private func assertHistory(_ expected: [String]) async throws {
        let (data, _) = try await URLSession.shared.data(from: URL(string: "\(address)/api/sessions/fixture/messages")!)
        let response = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: [[String: String]]])
        XCTAssertEqual(response["messages"]?.compactMap { $0["content"] }, expected)
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
        app.buttons["chat.send"].tap()
    }

    @MainActor
    private func replaceComposer(with text: String, in app: XCUIApplication) {
        let field = composer(in: app)
        field.tap()
        let existing = field.value as? String ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count) + text)
    }

    @MainActor
    private func waitForReply(_ text: String, in app: XCUIApplication) {
        XCTAssertTrue(app.staticTexts[text].waitForExistence(timeout: 10))
    }

    @MainActor
    private func openReplyMenu(in app: XCUIApplication) {
        app.staticTexts["chat.message.reply"].firstMatch.press(forDuration: 1)
        XCTAssertTrue(app.buttons["message.action.copy"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func openUserMenu(in app: XCUIApplication) {
        app.staticTexts["chat.message.user"].firstMatch.press(forDuration: 1)
        XCTAssertTrue(app.buttons["message.action.copy"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
