import XCTest

@MainActor
final class ToolCallDetailsTests: XCTestCase {
    private let fixtureID = UUID()
    private var address: String { "http://127.0.0.1:18765/\(fixtureID)" }

    func testOpenRunningToolAndWatchItComplete() async throws {
        let app = launch(address)
        send("Read the project notes", in: app)
        try await advance("tool-short", phase: "delta")
        open(in: app)
        XCTAssertEqual(detail("name", in: app).label, "read_file")
        XCTAssertEqual(detail("status", in: app).label, "Running")
        XCTAssertFalse(detail("timing", in: app).exists)
        XCTAssertTrue(payload("input", in: app).contains("PROJECT.md"))
        let waiting = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", "Waiting for output")).firstMatch
        XCTAssertTrue(waiting.waitForExistence(timeout: 5))
        screenshot("tool-running")

        try await advance("tool-short", phase: "end")
        let status = detail("status", in: app)
        let completed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "Completed"), object: status)
        await fulfillment(of: [completed], timeout: 10)
        XCTAssertTrue(status.label.contains("0.42"))
        XCTAssertTrue(app.staticTexts["0.42 s"].exists, app.debugDescription)
        XCTAssertFalse(app.staticTexts["Started"].exists)
        XCTAssertFalse(app.staticTexts["Finished"].exists)
        XCTAssertTrue(payload("output", in: app).contains("Release checklist"))
        screenshot("tool-short-output")
        app.buttons["tool.details.done"].tap()
        XCTAssertTrue(app.buttons["chat.tool.row"].firstMatch.waitForExistence(timeout: 5))
    }

    func testLongOutputIsCompleteAndScrollable() async throws {
        let app = launch(address)
        send("Read the build log", in: app)
        try await advance("tool-long", phase: "delta")
        try await advance("tool-long", phase: "end")
        XCTAssertTrue(app.buttons["chat.reply.completed"].waitForExistence(timeout: 10))
        open(in: app)
        XCTAssertTrue(payload("output", in: app).contains("0001 | Asset catalog check passed"))
        let expand = app.buttons["tool.details.showAll"]
        reveal(expand, in: app)
        XCTAssertEqual(expand.label, "Show 2,000 of 3,201 Lines")
        screenshot("tool-long-output")
        expand.tap()
        XCTAssertTrue(app.staticTexts["Showing 2,000 of 3,201 lines. Copy output for the full text."].exists)
        XCTAssertTrue(app.buttons["tool.details.copy.output"].exists)
        XCTAssertFalse(expand.exists)
    }

    func testFailedCompletionCanBeOpenedWithoutAStartEvent() async throws {
        let app = launch(address)
        send("Read a missing file", in: app)
        try await advance("tool-failed", phase: "delta")
        open(in: app)
        XCTAssertTrue(detail("status", in: app).label.contains("Failed"))
        XCTAssertTrue(detail("status", in: app).label.contains("exit 1"))
        XCTAssertTrue(detail("status", in: app).label.contains("0.42"))
        XCTAssertFalse(app.staticTexts["Finished"].exists)
        XCTAssertTrue(payload("input", in: app).contains("drafts/release-notes.md"))
        XCTAssertTrue(payload("output", in: app).contains("File not found"))
        screenshot("tool-failed")
    }

    func testSavedResultsAreMatchedByCallIDInsteadOfOrder() {
        let app = launch("http://127.0.0.1:18765/tool-history-\(fixtureID)")
        let previous = app.buttons["Saved tool calls"].firstMatch
        XCTAssertTrue(previous.waitForExistence(timeout: 10))
        previous.tap()
        open(in: app)
        XCTAssertTrue(payload("input", in: app).contains("NOTES.md"))
        XCTAssertTrue(payload("output", in: app).contains("Archived notes"))
        XCTAssertTrue(app.staticTexts["From saved transcript timestamps."].exists)
        if UIDevice.current.userInterfaceIdiom != .pad {
            app.buttons["tool.details.done"].tap()
        }
        open(in: app, index: 1)
        XCTAssertEqual(payload("output", in: app), "Readme result")
        if UIDevice.current.userInterfaceIdiom == .pad {
            XCTAssertTrue(app.navigationBars.staticTexts["Saved tool calls"].exists)
        }
    }

    private func launch(_ address: String) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-hermes.address", address, "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        return app
    }

    private func send(_ text: String, in app: XCUIApplication) {
        let newChat = app.buttons["chats.new"]
        XCTAssertTrue(newChat.waitForExistence(timeout: 10))
        newChat.tap()
        let field = app.descendants(matching: .any)["chat.composer"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText(text)
        let send = app.buttons["chat.send"]
        send.tap()
        let sent = app.staticTexts[text]
        if !sent.waitForExistence(timeout: 2), field.value as? String == text, send.isEnabled { send.tap() }
        XCTAssertTrue(sent.waitForExistence(timeout: 5))
    }

    private func open(in app: XCUIApplication, index: Int = 0) {
        let row = app.buttons.matching(identifier: "chat.tool.row").element(boundBy: index)
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        XCTAssertTrue(detail("name", in: app).waitForExistence(timeout: 5))
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        let scroll = app.scrollViews["tool.details"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 5))
        for _ in 0..<5 {
            if element.isHittable { return }
            scroll.swipeUp()
        }
        XCTAssertTrue(element.isHittable)
    }

    private func detail(_ name: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@", "tool.details.\(name)")).firstMatch
    }

    private func payload(_ name: String, in app: XCUIApplication) -> String {
        let element = detail(name, in: app)
        if !element.waitForExistence(timeout: 2) { reveal(element, in: app) }
        return element.value as? String ?? element.label
    }

    private func advance(_ scenario: String, phase: String) async throws {
        var request = URLRequest(url: URL(string: "\(address)/fixture/\(scenario)/\(phase)")!, timeoutInterval: 5)
        request.httpMethod = "POST"
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 204)
    }

    private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
