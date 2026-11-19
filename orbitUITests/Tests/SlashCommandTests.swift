import XCTest

final class SlashCommandTests: XCTestCase {
    @MainActor
    func testServerCommandsAndFiltering() {
        let app = launch()
        app.buttons["chats.new"].tap()
        let draft = composer(app)
        XCTAssertTrue(draft.waitForExistence(timeout: 10))
        draft.tap()
        draft.typeText("/")
        XCTAssertTrue(app.buttons["slash.command.help"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["slash.command.model"].exists)
        shot("slash-menu")
        draft.typeText("mo")
        XCTAssertFalse(app.buttons["slash.command.help"].exists)
        XCTAssertTrue(app.buttons["slash.command.model"].exists)
        shot("slash-filtered")
        app.buttons["slash.command.model"].tap()
        XCTAssertEqual(draft.value as? String, "/model ")
        XCTAssertFalse(app.scrollViews["slash.menu"].exists)
    }

    @MainActor
    func testCreateInsertAndSendSnippet() {
        let app = launch()
        app.buttons["chats.new"].tap()
        let draft = composer(app)
        XCTAssertTrue(draft.waitForExistence(timeout: 10))
        draft.tap()
        draft.typeText("/unique")
        app.buttons["slash.newSnippet"].tap()
        XCTAssertFalse(app.buttons["snippet.save"].isEnabled)
        fillEditor(app, title: "Unique prompt", body: "Summarize this conversation.")
        shot("snippet-editor")
        app.buttons["snippet.save"].tap()
        let row = app.buttons["slash.snippet.Unique prompt"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertEqual(draft.value as? String, "Summarize this conversation.")
        app.buttons["chat.send"].tap()
        let bubble = app.staticTexts["chat.user.Summarize this conversation."]
        if !bubble.waitForExistence(timeout: 2), app.buttons["chat.send"].isEnabled {
            app.buttons["chat.send"].tap()
        }
        XCTAssertTrue(bubble.waitForExistence(timeout: 5))
    }

    @MainActor
    func testManageSnippetsInSettings() {
        let app = launch()
        app.buttons["chats.settings"].tap()
        let link = app.buttons["settings.snippets"]
        for _ in 0..<4 where !link.isHittable { app.swipeUp() }
        link.tap()
        app.buttons["snippets.add"].tap()
        fillEditor(app, title: "Manage me", body: "Original prompt")
        app.buttons["snippet.save"].tap()
        let row = app.buttons["snippets.row.Manage me"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        let title = app.textFields["snippet.title"]
        title.tap()
        title.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "Manage me".count) + "Edited prompt")
        app.buttons["snippet.save"].tap()
        let edited = app.buttons["snippets.row.Edited prompt"]
        XCTAssertTrue(edited.waitForExistence(timeout: 5))
        shot("snippets-settings")
        edited.swipeLeft()
        let delete = app.buttons.matching(identifier: "Delete").firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 3))
        delete.tap()
        XCTAssertTrue(edited.waitForNonExistence(timeout: 5))
    }

    @MainActor
    private func launch() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-hermes.address", "http://127.0.0.1:18765/\(UUID())", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["HERMES_TEST_SNIPPETS"] = "[]"
        app.launch()
        XCTAssertTrue(app.buttons["chats.new"].waitForExistence(timeout: 10))
        return app
    }

    @MainActor
    private func composer(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["chat.composer"].firstMatch
    }

    @MainActor
    private func fillEditor(_ app: XCUIApplication, title: String, body: String) {
        let field = app.textFields["snippet.title"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(title)
        let prompt = app.textViews["snippet.body"]
        prompt.tap()
        prompt.typeText(body)
    }

    @MainActor
    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
