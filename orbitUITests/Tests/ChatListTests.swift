import XCTest

final class ChatListTests: XCTestCase {
    private let fixtureID = UUID()
    private var address: String { "http://127.0.0.1:18765/\(fixtureID)" }

    private func fixture(_ path: String) async throws {
        var request = URLRequest(url: URL(string: address + "/fixture/" + path)!)
        request.httpMethod = "POST"
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 204)
    }

    @MainActor private func launch(dark: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-hermes.address", address, "-hermes.theme", dark ? "dark" : "light",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.buttons["chats.new"].waitForExistence(timeout: 10))
        return app
    }

    @MainActor private func row(_ id: String, _ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["chats.row." + id].firstMatch
    }

    @MainActor private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor func testSortPinRenameDeleteAndRevert() async throws {
        continueAfterFailure = false
        try await fixture("seed")
        let app = launch()
        let pinned = row("pinned", app), recent = row("fixture", app), older = row("older", app)
        XCTAssertTrue(recent.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Pinned"].exists)
        XCTAssertTrue(app.staticTexts["Recent"].exists)
        XCTAssertLessThan(pinned.frame.minY, recent.frame.minY)
        XCTAssertLessThan(recent.frame.minY, older.frame.minY)
        recent.swipeRight()
        shot("list-leading-pin")
        app.buttons["chats.swipe.pin"].tap()
        XCTAssertTrue(recent.waitForExistence(timeout: 5))
        XCTAssertTrue((recent.value as? String ?? "").contains("pinned"))
        recent.swipeRight()
        app.buttons["chats.swipe.pin"].tap()
        recent.swipeLeft()
        shot("list-trailing-actions")
        app.buttons["chats.swipe.rename"].tap()
        let field = app.alerts["Rename Chat"].textFields["Chat name"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        shot("list-rename-alert")
        field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 30) + "Renamed ideas")
        app.alerts.buttons["Save"].tap()
        XCTAssertTrue(app.staticTexts["Renamed ideas"].waitForExistence(timeout: 5))
        older.swipeLeft()
        app.buttons["chats.swipe.delete"].tap()
        let deleteAlert = app.alerts["Delete \"Weekend plans\"?"]
        XCTAssertTrue(deleteAlert.waitForExistence(timeout: 5))
        shot("list-delete-alert")
        deleteAlert.buttons["Cancel"].tap()
        XCTAssertTrue(older.exists)
        older.swipeLeft()
        app.buttons["chats.swipe.delete"].tap()
        deleteAlert.buttons["chats.delete.confirm"].firstMatch.tap()
        XCTAssertTrue(older.waitForNonExistence(timeout: 5))
        try await fixture("fail-patch")
        recent.swipeRight()
        app.buttons["chats.swipe.pin"].tap()
        XCTAssertTrue(app.alerts["Couldn't Pin Chat"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["This Hermes server doesn't support that yet."].exists)
        app.alerts.buttons["OK"].tap()
        XCTAssertFalse((recent.value as? String ?? "").contains("pinned"))
    }

    @MainActor func testReplyingAndEmptyStates() async throws {
        continueAfterFailure = false
        try await fixture("seed")
        let app = launch()
        let recent = row("fixture", app)
        XCTAssertTrue(recent.waitForExistence(timeout: 10))
        recent.tap()
        let composer = app.descendants(matching: .any)["chat.composer"].firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        composer.tap()
        composer.typeText("Complete the reply")
        app.buttons["chat.send"].tap()
        try await fixture("complete/delta")
        XCTAssertTrue(app.staticTexts["chat.reply.streaming"].waitForExistence(timeout: 10))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(recent.waitForExistence(timeout: 5))
        XCTAssertTrue((recent.value as? String ?? "").contains("Replying"))
        shot("list-pinned-recent-replying")
        try await fixture("complete/end")
        let ended = NSPredicate(format: "NOT (value CONTAINS %@)", "Replying")
        let finished = expectation(for: ended, evaluatedWith: recent)
        await fulfillment(of: [finished], timeout: 10)
        let completedValue = recent.value as? String ?? ""
        XCTAssertTrue(completedValue.contains("now"), completedValue)
        XCTAssertFalse(completedValue.contains("in "), completedValue)
        app.terminate()
        let dark = launch(dark: true)
        XCTAssertTrue(row("fixture", dark).waitForExistence(timeout: 10))
        shot("list-dark")
        dark.terminate()
        try await fixture("empty")
        let empty = launch()
        XCTAssertTrue(empty.descendants(matching: .any)["chats.empty"].firstMatch.waitForExistence(timeout: 10))
        shot("list-empty")
    }

    @MainActor func testDarkReplyingPulse() async throws {
        continueAfterFailure = false
        try await fixture("seed")
        let app = launch(dark: true)
        let recent = row("fixture", app)
        XCTAssertTrue(recent.waitForExistence(timeout: 10))
        recent.tap()
        let composer = app.descendants(matching: .any)["chat.composer"].firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        composer.tap()
        composer.typeText("Complete the reply")
        app.buttons["chat.send"].tap()
        try await fixture("complete/delta")
        XCTAssertTrue(app.staticTexts["chat.reply.streaming"].waitForExistence(timeout: 10))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(recent.waitForExistence(timeout: 5))
        XCTAssertTrue((recent.value as? String ?? "").contains("Replying"))
        shot("list-dark-replying")
        for frame in 1...3 {
            try await Task.sleep(for: .milliseconds(250))
            shot("list-dark-replying-pulse-\(frame)")
        }
        recent.swipeLeft()
        app.buttons["chats.swipe.delete"].tap()
        XCTAssertTrue(app.alerts.staticTexts["Research ideas is still replying. Deleting stops the reply and removes the chat from 127.0.0.1."].exists)
        app.alerts.buttons["Cancel"].tap()
        try await fixture("complete/end")
    }

    @MainActor func testCompletedReplyUsesPresentAccessibilityTime() async throws {
        continueAfterFailure = false
        try await fixture("seed")
        let app = launch()
        let recent = row("fixture", app)
        XCTAssertTrue(recent.waitForExistence(timeout: 10))
        recent.tap()
        let composer = app.descendants(matching: .any)["chat.composer"].firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        composer.tap()
        composer.typeText("Complete the reply")
        app.buttons["chat.send"].tap()
        try await fixture("complete/delta")
        XCTAssertTrue(app.staticTexts["chat.reply.streaming"].waitForExistence(timeout: 10))
        try await fixture("complete/end")
        XCTAssertTrue(app.buttons["chat.reply.completed"].waitForExistence(timeout: 10))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(recent.waitForExistence(timeout: 5))
        let value = recent.value as? String ?? ""
        XCTAssertEqual(value, "now")
        XCTAssertFalse(value.contains("in "), value)
    }
}
