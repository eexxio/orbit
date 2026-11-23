import XCTest

final class AttachmentTests: XCTestCase {
    private var fixture = ""
    @MainActor
    func testAttachThenRemove() {
        let app = launchChat()
        let item = element("chat.tray.item", in: app)
        XCTAssertTrue(item.waitForExistence(timeout: 10))
        let remove = app.buttons["chat.tray.remove"]
        XCTAssertTrue(remove.label.hasPrefix("Remove Planet."))
        XCTAssertGreaterThanOrEqual(remove.frame.width, 44)
        XCTAssertGreaterThanOrEqual(remove.frame.height, 44)
        remove.tap()
        XCTAssertTrue(item.waitForNonExistence(timeout: 5))
        XCTAssertFalse(element("chat.tray", in: app).exists)
    }

    @MainActor
    func testAttachThenSend() {
        let app = launchChat()
        XCTAssertTrue(element("chat.tray.item", in: app).waitForExistence(timeout: 10))
        app.buttons["chat.send"].tap()
        XCTAssertTrue(element("chat.message.attachment", in: app).waitForExistence(timeout: 10))
        let completed = element("chat.reply.completed", in: app)
        XCTAssertTrue(completed.waitForExistence(timeout: 10))
        XCTAssertEqual(completed.value as? String, "Got 1 attachment(s)")
        XCTAssertFalse(element("chat.tray", in: app).exists)
        screenshot("attachment-sent")
    }

    @MainActor
    func testAttachImageAndFile() {
        let app = launchChat(multiple: true)
        let items = app.descendants(matching: .any).matching(identifier: "chat.tray.item")
        XCTAssertTrue(items.firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(items.count, 2)
        XCTAssertTrue(app.buttons.matching(identifier: "chat.tray.remove").allElementsBoundByIndex.map(\.label).contains("Remove notes.txt"))
        screenshot("attachment-tray")
        app.buttons["chat.send"].tap()
        XCTAssertTrue(element("chat.reply.completed", in: app).waitForExistence(timeout: 10))
        XCTAssertEqual(element("chat.reply.completed", in: app).value as? String, "Got 2 attachment(s)")
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "chat.message.attachment").count, 2)
        let sizes = app.descendants(matching: .any).matching(identifier: "chat.message.attachment")
            .allElementsBoundByIndex.compactMap { $0.value as? String }
        XCTAssertTrue(sizes.contains("18 bytes"))
    }

    @MainActor
    func testUnsupportedServerHidesAttach() {
        let app = launchChat(unsupported: true)
        XCTAssertTrue(element("chat.tray.item", in: app).waitForExistence(timeout: 10))
        let composer = element("chat.composer", in: app)
        composer.tap()
        composer.typeText("Please read this")
        app.buttons["chat.send"].tap()
        XCTAssertTrue(element("chat.reply.failed", in: app).waitForExistence(timeout: 10))
        XCTAssertEqual(element("chat.reply.error", in: app).label, "This Hermes server can't take attachments")
        XCTAssertFalse(element("chat.attach", in: app).exists)
        XCTAssertEqual(composer.value as? String, "Please read this")
        let fallback = app.buttons["chat.sendWithoutAttachments"]
        XCTAssertTrue(fallback.exists)
        screenshot("attachment-unsupported")
        fallback.tap()
        XCTAssertTrue(element("chat.reply.completed", in: app).waitForExistence(timeout: 10))
        XCTAssertEqual(element("chat.reply.completed", in: app).value as? String, "Text-only reply")
        XCTAssertEqual(composer.value as? String, "")
    }

    @MainActor
    func testUnsupportedWithoutTextHasNoFallback() {
        let app = launchChat(unsupported: true)
        XCTAssertTrue(element("chat.tray.item", in: app).waitForExistence(timeout: 10))
        app.buttons["chat.send"].tap()
        XCTAssertTrue(element("chat.reply.failed", in: app).waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["chat.sendWithoutAttachments"].exists)
        XCTAssertEqual(element("chat.composer", in: app).value as? String, "")
    }

    @MainActor
    func testMethodSpecificInvalidParamsHidesAttach() {
        let app = launchChat(scenario: "unsupported-invalid-")
        XCTAssertTrue(element("chat.tray.item", in: app).waitForExistence(timeout: 10))
        app.buttons["chat.send"].tap()
        XCTAssertTrue(element("chat.reply.failed", in: app).waitForExistence(timeout: 10))
        XCTAssertFalse(element("chat.attach", in: app).exists)
        XCTAssertEqual(element("chat.reply.error", in: app).label, "This Hermes server can't take attachments")
    }

    @MainActor
    func testOtherStagingErrorsKeepAttachmentSupport() {
        for scenario in ["staging-error-", "invalid-other-", "malformed-"] {
            let app = launchChat(scenario: scenario)
            XCTAssertTrue(element("chat.tray.item", in: app).waitForExistence(timeout: 10))
            app.buttons["chat.send"].tap()
            XCTAssertTrue(element("chat.reply.failed", in: app).waitForExistence(timeout: 10))
            XCTAssertTrue(element("chat.attach", in: app).exists)
            XCTAssertNotEqual(element("chat.reply.error", in: app).label, "This Hermes server can't take attachments")
            XCTAssertFalse(app.buttons["chat.sendWithoutAttachments"].exists)
            app.terminate()
        }
    }

    @MainActor
    func testStopDuringStagingDoesNotSubmit() async throws {
        let app = launchChat(multiple: true, scenario: "staging-stop-")
        XCTAssertTrue(element("chat.tray.item", in: app).waitForExistence(timeout: 10))
        app.buttons["chat.send"].tap()
        try await waitForStat("images", value: 1)
        app.buttons["chat.stop"].tap()
        XCTAssertTrue(element("chat.reply.stopped", in: app).waitForExistence(timeout: 5))
        var release = URLRequest(url: URL(string: "http://127.0.0.1:18765/\(fixture)/fixture/attachment/release")!)
        release.httpMethod = "POST"
        let (_, response) = try await URLSession.shared.data(for: release)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 204)
        try await waitForStat("detached", value: 1)
        let state = try await fixtureState()
        XCTAssertEqual(state["prompts"], 0)
        XCTAssertEqual(state["files"], 0)
        XCTAssertEqual(state["images"], 1)
        XCTAssertTrue(element("chat.reply.stopped", in: app).exists)
        XCTAssertFalse(element("chat.reply.failed", in: app).exists)
    }

    private func fixtureState() async throws -> [String: Int] {
        let (data, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:18765/\(fixture)/fixture/state")!)
        return try JSONDecoder().decode([String: Int].self, from: data)
    }

    private func waitForStat(_ key: String, value: Int) async throws {
        for _ in 0..<100 {
            if try await fixtureState()[key] == value { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("Fixture did not reach \(key)=\(value)")
    }

    @MainActor
    private func launchChat(unsupported: Bool = false, multiple: Bool = false, scenario: String = "") -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        fixture = (unsupported ? "unsupported-" : scenario) + UUID().uuidString
        app.launchArguments = ["-hermes.address", "http://127.0.0.1:18765/\(fixture)", multiple ? "-attachment-fixtures" : "-attachment-fixture", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.buttons["chats.new"].waitForExistence(timeout: 10))
        app.buttons["chats.new"].tap()
        return app
    }

    @MainActor
    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @MainActor
    private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
