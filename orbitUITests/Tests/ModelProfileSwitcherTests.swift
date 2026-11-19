import XCTest

@MainActor
final class ModelProfileSwitcherTests: XCTestCase {
    private var address = ""

    func testSelectProfileAndModelBeforeFirstMessage() async throws {
        let app = openChat("profile", existing: false)
        let title = app.buttons["chat.modelSwitcher"]
        let resolvedDefault = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Model, example/sonnet, profile default"),
                                                        object: title)
        await fulfillment(of: [resolvedDefault], timeout: 8)
        snapshot("switcher-01-new-chat-title")
        openPicker(app)
        let work = app.buttons["profileRow.work"]
        XCTAssertTrue(work.waitForExistence(timeout: 10))
        snapshot("switcher-02-new-chat-picker")
        work.tap()
        let workModel = model("work-fast", app)
        XCTAssertTrue(workModel.waitForExistence(timeout: 10))
        XCTAssertFalse(model("opus", app).exists)
        snapshot("switcher-03-work-profile")
        reveal(workModel, app)
        snapshot("switcher-16-model-list")
        workModel.tap()
        XCTAssertTrue(app.buttons["chat.modelSwitcher"].label.contains("work-fast"))
        let draft = try await state()
        XCTAssertNil(draft["created_profile"])
        send("Use my work model", app)
        XCTAssertTrue(app.staticTexts["The next reply arrived."].waitForExistence(timeout: 10))
        let created = try await state()
        XCTAssertEqual(created["created_profile"], "work")
        XCTAssertEqual(created["created_model"], "example/work-fast")
        XCTAssertEqual(created["created_provider"], "example")
        app.navigationBars.buttons["Chats"].tap()
        XCTAssertTrue(app.buttons["Created chat"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["Existing chat"].exists)
    }

    func testExistingChatCanStartAnotherProfileWithoutMovingHistory() async throws {
        let app = openChat("canonical", existing: true)
        openPicker(app)
        XCTAssertTrue(element("modelPicker.lockedProfile", app).waitForExistence(timeout: 8))
        snapshot("switcher-04-existing-profile-locked")
        let newChat = app.buttons["modelPicker.newChatInProfile"]
        reveal(newChat, app)
        newChat.tap()
        XCTAssertTrue(app.navigationBars["New chat in"].waitForExistence(timeout: 5))
        snapshot("switcher-05-new-chat-in-another-profile")
        app.buttons["profileRow.work"].tap()
        XCTAssertTrue(app.staticTexts["New chat"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["chat.modelSwitcher"].label.contains("profile work"))
        XCTAssertFalse(app.staticTexts["Earlier chat history."].exists)
        let before = try await state()
        XCTAssertNil(before["created_profile"])
        XCTAssertNil(before["mutations"])
    }

    func testQueueModelUntilTheReplyFinishes() async throws {
        let app = openChat("canonical", existing: true)
        send("Complete the reply", app)
        try await advance("delta")
        XCTAssertTrue(element("chat.reply.streaming", app).waitForExistence(timeout: 8))
        openPicker(app)
        let opus = model("opus", app)
        reveal(opus, app)
        opus.tap()
        XCTAssertTrue(element("chat.modelPending", app).waitForExistence(timeout: 8))
        let before = try await state()
        XCTAssertNil(before["mutations"])
        snapshot("switcher-06-queued")
        try await advance("end")
        XCTAssertTrue(element("chat.modelChanged", app).waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["chat.modelSwitcher"].label.contains("example/opus"))
        snapshot("switcher-07-applied")
        send("Use the switched model", app)
        XCTAssertTrue(app.staticTexts["The next reply arrived."].waitForExistence(timeout: 8))
        let applied = try await state()
        XCTAssertEqual(applied["mutation_method"], "session.mutate")
        XCTAssertEqual(applied["prompt_model"], "example/opus")
        app.navigationBars.buttons["Chats"].tap()
        app.buttons["chats.new"].tap()
        XCTAssertFalse(app.buttons["chat.modelSwitcher"].label.contains("example/opus"))
    }

    func testServerConfirmationAndRefusal() async throws {
        let app = openChat("canonical", existing: true)
        openPicker(app)
        let guarded = model("guarded", app)
        reveal(guarded, app)
        guarded.tap()
        let use = app.buttons["Use guarded"]
        XCTAssertTrue(use.waitForExistence(timeout: 10))
        let before = try await state()
        XCTAssertNil(before["mutations"])
        snapshot("switcher-08-confirmation")
        use.tap()
        XCTAssertTrue(element("chat.modelChanged", app).waitForExistence(timeout: 8))
        openPicker(app)
        let refused = model("refused", app)
        reveal(refused, app)
        refused.tap()
        XCTAssertTrue(element("modelPicker.switchError", app).waitForExistence(timeout: 8))
        XCTAssertEqual(guarded.value as? String, "Selected")
        XCTAssertNotEqual(refused.value as? String, "Selected")
        snapshot("switcher-09-refusal")
        XCTAssertTrue(app.buttons["modelPicker.done"].exists)
        app.buttons["modelPicker.done"].tap()
        XCTAssertTrue(app.buttons["chat.modelSwitcher"].label.contains("example/guarded"))
        let after = try await state()
        XCTAssertEqual(after["model"], "example/guarded")
    }

    func testFallbackUsesOnlyTheLiveSession() async throws {
        let app = openChat("fallback", existing: true)
        openPicker(app)
        let opus = model("opus", app)
        reveal(opus, app)
        opus.tap()
        XCTAssertTrue(element("chat.modelChanged", app).waitForExistence(timeout: 10))
        let applied = try await state()
        XCTAssertEqual(applied["unsupported_mutations"], "1")
        XCTAssertEqual(applied["mutation_method"], "config.set")
        XCTAssertEqual(applied["model"], "example/opus")
    }

    func testUnavailableCurrentModel() throws {
        let app = openChat("retired", existing: true)
        openPicker(app)
        let retired = element("modelPicker.unavailable", app)
        reveal(retired, app)
        XCTAssertTrue(retired.label.contains("Not available"))
        snapshot("switcher-10-unavailable-current-model")
    }

    func testNoAuthenticatedProviders() throws {
        let app = openChat("empty", existing: false)
        openPicker(app)
        let empty = element("modelPicker.noModels", app)
        reveal(empty, app)
        XCTAssertFalse(model("hidden-model", app).exists)
        snapshot("switcher-11-no-authenticated-providers")
    }

    func testServerNeedsRestartToListModels() throws {
        let app = openChat("skew", existing: false)
        openPicker(app)
        let error = element("modelPicker.listError", app)
        reveal(error, app)
        XCTAssertTrue(error.label.contains("needs a restart"))
        snapshot("switcher-12-restart-required")
    }

    func testOfflineDisablesSelectionAndKeepsHistory() async throws {
        let app = openChat("offline", existing: true)
        openPicker(app)
        let opus = model("opus", app)
        reveal(opus, app)
        XCTAssertTrue(opus.isEnabled)
        app.buttons["modelPicker.done"].tap()
        try await fixturePost("offline")
        openPicker(app)
        XCTAssertTrue(app.staticTexts["Offline: showing saved list"].waitForExistence(timeout: 10))
        snapshot("switcher-13-offline")
        reveal(opus, app)
        XCTAssertFalse(opus.isEnabled)
        app.buttons["modelPicker.done"].tap()
        XCTAssertTrue(app.staticTexts["Earlier chat history."].exists)
    }

    func testRemovedProfileLeavesChatReadOnlyAndFallsBack() async throws {
        let app = openChat("removed", existing: true)
        XCTAssertTrue(app.staticTexts["Earlier chat history."].waitForExistence(timeout: 8))
        try await fixturePost("removed")
        openPicker(app)
        app.buttons["modelPicker.done"].tap()
        XCTAssertTrue(app.staticTexts["This chat’s profile was removed on the server."].waitForExistence(timeout: 8))
        XCTAssertFalse(element("chat.composer", app).exists)
        XCTAssertTrue(app.staticTexts["Earlier chat history."].exists)
        let newChat = app.buttons["New chat"]
        XCTAssertTrue(newChat.isHittable)
        XCTAssertGreaterThanOrEqual(newChat.frame.width, 44)
        XCTAssertGreaterThanOrEqual(newChat.frame.height, 44)
        snapshot("switcher-14-removed-profile-chat")
        app.navigationBars.buttons["Chats"].tap()
        XCTAssertTrue(app.staticTexts["Profile “work” was removed on the server. Showing “default”."].waitForExistence(timeout: 8))
        snapshot("switcher-15-removed-profile-fallback")
    }

    func testMutationConflictRefreshesRevisionAndRetriesOnce() async throws {
        let app = openChat("conflict", existing: true)
        openPicker(app)
        let opus = model("opus", app)
        reveal(opus, app)
        opus.tap()
        XCTAssertTrue(element("chat.modelChanged", app).waitForExistence(timeout: 10))
        let applied = try await state()
        XCTAssertEqual(applied["conflicts"], "1")
        XCTAssertEqual(applied["resumes"], "3")
        XCTAssertEqual(applied["mutations"], "1")
        XCTAssertEqual(applied["model"], "example/opus")
    }

    private func openChat(_ mode: String, existing: Bool) -> XCUIApplication {
        continueAfterFailure = false
        address = "http://127.0.0.1:18765/\(mode)-\(UUID())"
        let app = XCUIApplication()
        app.launchArguments = ["-hermes.address", address, "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let entry = app.buttons[existing ? "Existing chat" : "chats.new"]
        XCTAssertTrue(entry.waitForExistence(timeout: 10))
        entry.tap()
        XCTAssertTrue(app.buttons["chat.modelSwitcher"].waitForExistence(timeout: 8))
        return app
    }

    private func openPicker(_ app: XCUIApplication) {
        app.buttons["chat.modelSwitcher"].tap()
        XCTAssertTrue(app.buttons["modelPicker.done"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.navigationBars["Chat Settings"].exists)
    }

    private func model(_ name: String, _ app: XCUIApplication) -> XCUIElement {
        app.buttons["modelRow.\(name == "hidden-model" ? name : "example/\(name)")"]
    }

    private func element(_ id: String, _ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func reveal(_ row: XCUIElement, _ app: XCUIApplication) {
        for _ in 0..<4 {
            if row.waitForExistence(timeout: 2), row.isHittable { return }
            let list = element("modelPicker.list", app)
            XCTAssertTrue(list.exists)
            list.swipeUp()
        }
        XCTAssertTrue(row.exists && row.isHittable)
    }

    private func send(_ text: String, _ app: XCUIApplication) {
        let composer = element("chat.composer", app)
        composer.tap()
        composer.typeText(text)
        let send = app.buttons["chat.send"]
        XCTAssertTrue(send.isEnabled)
        send.tap()
        if !app.staticTexts[text].waitForExistence(timeout: 2), send.isEnabled { send.tap() }
        XCTAssertTrue(app.staticTexts[text].waitForExistence(timeout: 5))
    }

    private func advance(_ phase: String) async throws {
        try await fixturePost("complete/\(phase)")
    }

    private func fixturePost(_ path: String) async throws {
        var request = URLRequest(url: URL(string: "\(address)/fixture/\(path)")!)
        request.httpMethod = "POST"
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 204)
    }

    private func state() async throws -> [String: String] {
        let (data, _) = try await URLSession.shared.data(from: URL(string: "\(address)/fixture/state")!)
        let values = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return values.mapValues { String(describing: $0) }
    }

    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
