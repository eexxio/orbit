import XCTest

final class AttachmentTests: XCTestCase {
    @MainActor
    func testAttachThenRemove() {
        let app = launchChat()
        let item = element("chat.tray.item", in: app)
        XCTAssertTrue(item.waitForExistence(timeout: 10))
        item.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.15)).tap()
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
        app.buttons["chat.send"].tap()
        XCTAssertTrue(element("chat.reply.completed", in: app).waitForExistence(timeout: 10))
        XCTAssertEqual(element("chat.reply.completed", in: app).value as? String, "Got 2 attachment(s)")
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "chat.message.attachment").count, 2)
    }

    @MainActor
    func testUnsupportedServerHidesAttach() {
        let app = launchChat(unsupported: true)
        XCTAssertTrue(element("chat.tray.item", in: app).waitForExistence(timeout: 10))
        app.buttons["chat.send"].tap()
        XCTAssertTrue(element("chat.reply.failed", in: app).waitForExistence(timeout: 10))
        XCTAssertEqual(element("chat.reply.error", in: app).label, "This Hermes server can't take attachments")
        XCTAssertFalse(element("chat.attach", in: app).exists)
        screenshot("attachment-unsupported")
    }

    @MainActor
    private func launchChat(unsupported: Bool = false, multiple: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        let fixture = (unsupported ? "unsupported-" : "") + UUID().uuidString
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
