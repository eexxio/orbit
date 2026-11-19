import XCTest

final class SlashCommandTests: XCTestCase {
    private var fixtureID = UUID().uuidString
    @MainActor
    func testPickerFilteringAndLocalHelp() async throws {
        let app = launch()
        app.buttons["chats.new"].tap()
        let draft = composer(app)
        XCTAssertTrue(draft.waitForExistence(timeout: 10))
        draft.tap()
        draft.typeText("/")
        XCTAssertTrue(app.buttons["slash.command.help"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["slash.command.status"].exists)
        XCTAssertTrue(app.staticTexts["slash.commands"].isHittable)
        XCTAssertTrue(app.buttons["slash.command.help"].isHittable)
        XCTAssertTrue(app.buttons["slash.command.help"].isEnabled)
        for name in ["status", "context", "usage"] {
            let row = app.buttons["slash.command.\(name)"]
            XCTAssertTrue(row.exists)
            XCTAssertFalse(row.isEnabled)
            XCTAssertTrue(row.label.contains("Send a message first"))
        }
        shot("empty-picker")
        let initial = try await state()
        XCTAssertEqual(initial["creates"], 0)
        XCTAssertEqual(initial["resumes"], 0)
        XCTAssertEqual(initial["prompts"], 0)
        draft.typeText("zzzz")
        XCTAssertTrue(app.descendants(matching: .any)["slash.noMatch"].firstMatch.waitForExistence(timeout: 3))
        shot("no-match")
        draft.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 4) + "he")
        XCTAssertFalse(app.buttons["slash.command.status"].exists)
        XCTAssertTrue(app.buttons["slash.command.help"].exists)
        shot("filtered")
        app.buttons["slash.command.help"].tap()
        XCTAssertEqual(draft.value as? String, "/help")
        XCTAssertTrue(app.buttons["slash.armed"].exists)
        XCTAssertEqual(app.buttons["chat.send"].label, "Run command")
        shot("help-armed")
        app.buttons["chat.send"].tap()
        XCTAssertTrue(app.staticTexts["slash.result.output"].waitForExistence(timeout: 5))
        shot("help-result")
        app.buttons["slash.result.done"].tap()
    }

    @MainActor
    func testCreateInsertAndSendSnippet() async throws {
        let app = launch()
        app.buttons["chats.new"].tap()
        let draft = composer(app)
        XCTAssertTrue(draft.waitForExistence(timeout: 10))
        draft.tap()
        draft.typeText("/unique")
        XCTAssertEqual(draft.value as? String, "/unique")
        XCTAssertTrue(app.buttons["slash.newSnippet"].waitForExistence(timeout: 5))
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
        XCTAssertEqual(app.staticTexts.matching(identifier: "chat.user.Summarize this conversation.").count, 1)
        let counts = try await state()
        XCTAssertEqual(counts["prompts"], 1)
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
        shot("snippet-library")
        app.buttons["snippets.add"].tap()
        fillEditor(app, title: "  Édited prompt  ", body: "Duplicate")
        XCTAssertTrue(app.staticTexts["snippet.duplicate"].exists)
        XCTAssertFalse(app.buttons["snippet.save"].isEnabled)
        shot("snippet-editor-duplicate")
        app.buttons["snippet.cancel"].tap()
        app.buttons.matching(identifier: "snippet.discard").firstMatch.tap()
        XCTAssertTrue(app.textFields["snippet.title"].waitForNonExistence(timeout: 5))
        edited.swipeLeft()
        let delete = app.buttons["snippets.delete.Edited prompt"]
        XCTAssertTrue(delete.waitForExistence(timeout: 3))
        delete.tap()
        app.buttons.matching(identifier: "snippets.confirmDelete").firstMatch.tap()
        XCTAssertTrue(edited.waitForNonExistence(timeout: 5))
    }

    @MainActor
    func testRemoteStatusAndEmptyResultsWithoutSubmitting() async throws {
        let app = launch(scenario: "supported", seeded: true)
        let existing = app.buttons["chats.session.fixture"]
        XCTAssertTrue(existing.waitForExistence(timeout: 10))
        existing.tap()
        let draft = composer(app)
        XCTAssertTrue(draft.waitForExistence(timeout: 10))
        draft.tap()
        draft.typeText("/")
        XCTAssertTrue(app.buttons["slash.snippet.Summarize"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["slash.commands"].exists)
        XCTAssertFalse(app.buttons["slash.command.model"].exists)
        shot("picker-with-snippets")
        let before = try await state()
        XCTAssertEqual(before["prompts"], 0)
        XCTAssertEqual(before["creates"], 0)
        XCTAssertEqual(before["catalogs"], 1)
        draft.typeText("sta")
        let status = app.buttons["slash.command.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertTrue(status.isEnabled)
        status.tap()
        XCTAssertEqual(draft.value as? String, "/status")
        XCTAssertGreaterThanOrEqual(app.buttons["slash.armed"].frame.height, 44)
        XCTAssertGreaterThanOrEqual(app.buttons["slash.useAsMessage"].frame.height, 44)
        XCTAssertEqual(app.buttons["chat.send"].label, "Run command")
        shot("command-armed")
        app.buttons["slash.armed"].tap()
        let output = app.staticTexts["slash.result.output"]
        XCTAssertTrue(output.waitForExistence(timeout: 10))
        XCTAssertEqual(output.label, "Status: ready")
        shot("result-sheet")
        app.buttons["slash.result.done"].tap()
        for token in ["ctx", "usage"] {
            draft.tap()
            draft.typeText("/" + token)
            let canonical = token == "ctx" ? "context" : token
            app.buttons["slash.command.\(canonical)"].tap()
            XCTAssertEqual(draft.value as? String, "/\(canonical)")
            app.buttons["chat.send"].tap()
            XCTAssertTrue(output.waitForExistence(timeout: 10))
            XCTAssertEqual(output.label, "No information returned")
            app.buttons["slash.result.done"].tap()
        }
        let after = try await state()
        XCTAssertEqual(after["prompts"], 0)
        XCTAssertEqual(after["executions"], 3)
        XCTAssertEqual(after["creates"], 0)
        XCTAssertEqual(after["resumes"], 1)
        XCTAssertEqual(after["catalogs"], 1)
    }

    @MainActor
    func testUnsupportedAndRejectedCommands() async throws {
        for scenario in ["unsupported", "rejected", "denied"] {
            let app = launch(scenario: scenario)
            let existing = app.buttons["chats.session.fixture"]
            XCTAssertTrue(existing.waitForExistence(timeout: 10))
            existing.tap()
            let draft = composer(app)
            XCTAssertTrue(draft.waitForExistence(timeout: 10))
            draft.tap()
            draft.typeText("/status")
            let status = app.buttons["slash.command.status"]
            XCTAssertTrue(status.waitForExistence(timeout: 5))
            if scenario == "unsupported" { XCTAssertTrue(status.label.contains("Availability varies by server")) }
            status.tap()
            app.buttons["chat.send"].tap()
            let error = app.staticTexts["slash.error"]
            XCTAssertTrue(error.waitForExistence(timeout: 10))
            XCTAssertEqual(error.label, scenario == "denied" ? "Couldn't run /status. Try again." : "This server doesn't support /status")
            XCTAssertFalse(app.staticTexts["slash.result.output"].exists)
            XCTAssertEqual(draft.value as? String, "/status")
            if scenario != "denied" {
                XCTAssertFalse(app.buttons["slash.armed"].exists)
                XCTAssertFalse(app.buttons["chat.send"].exists)
                XCTAssertTrue(app.buttons["slash.useAsMessage"].exists)
            } else {
                XCTAssertTrue(app.buttons["slash.armed"].exists)
            }
            if scenario == "unsupported" { shot("unsupported") }
            let counts = try await state()
            XCTAssertEqual(counts["prompts"], 0)
            XCTAssertEqual(counts["executions"], 1)
            XCTAssertEqual(counts["creates"], 0)
            app.terminate()
        }
    }

    @MainActor
    func testDarkPicker() {
        let app = launch(scenario: "dark", seeded: true, dark: true)
        app.buttons["chats.new"].tap()
        let draft = composer(app)
        XCTAssertTrue(draft.waitForExistence(timeout: 10))
        draft.tap()
        draft.typeText("/")
        XCTAssertTrue(app.buttons["slash.snippet.Summarize"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["slash.command.help"].isEnabled)
        shot("picker-dark")
    }

    private func state() async throws -> [String: Int] {
        let url = URL(string: "http://127.0.0.1:18765/\(fixtureID)/fixture/state")!
        let (data, _) = try await URLSession.shared.data(from: url)
        return try JSONDecoder().decode([String: Int].self, from: data)
    }

    @MainActor
    private func launch(scenario: String? = nil, seeded: Bool = false, dark: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        fixtureID = scenario.map { "slash-\($0)-\(UUID())" } ?? UUID().uuidString
        app.launchArguments = ["-hermes.address", "http://127.0.0.1:18765/\(fixtureID)", "-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-hermes.theme", dark ? "dark" : "light"]
        app.launchEnvironment["HERMES_TEST_SNIPPETS"] = seeded
            ? #"[{"id":"5729ED5D-DB10-467B-A210-AECB7589A60B","name":"Summarize","body":"Summarize this conversation."}]"# : "[]"
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
