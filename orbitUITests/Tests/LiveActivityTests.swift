import XCTest

final class LiveActivityTests: XCTestCase {
    private let fixtureID = UUID()
    private var address: String { "http://127.0.0.1:18765/\(fixtureID)" }
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    @MainActor
    func testLongReplyShowsLiveActivityAndStopsFromIt() throws {
        let app = launch(liveActivities: true)
        send("Run a long task", in: app)
        XCTAssertTrue(button("chat.stop", in: app).waitForExistence(timeout: 10))

        // The activity waits out its start delay (2 s in tests) while the reply runs.
        sleep(4)
        XCUIDevice.shared.press(.home)
        let island = springboard.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Running a tool")).firstMatch
        XCTAssertTrue(island.waitForExistence(timeout: 15))
        screenshot("live-activity-island")

        island.press(forDuration: 1.2)
        let stop = springboard.buttons.matching(NSPredicate(format: "identifier == %@", "replyActivity.stop")).firstMatch
        XCTAssertTrue(stop.waitForExistence(timeout: 10))
        screenshot("live-activity-expanded")
        stop.tap()

        app.activate()
        XCTAssertTrue(app.staticTexts["chat.reply.stopped"].waitForExistence(timeout: 10))
        screenshot("chat-stopped-from-activity")
    }

    @MainActor
    func testSettingIsOffByDefault() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-hermes.address", address, "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let settings = button("chats.settings", in: app)
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()
        let toggle = app.switches.matching(NSPredicate(format: "identifier == %@", "settings.liveActivities")).firstMatch
        for _ in 0..<5 where !toggle.isHittable { app.swipeUp() }
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "0")
        XCTAssertTrue(app.staticTexts["Show agent progress on the Lock Screen and Dynamic Island. Chat text stays in orbit."].exists)
        screenshot("settings-live-activities")
    }

    @MainActor
    func testNoLiveActivityWhenTurnedOff() throws {
        let app = launch(liveActivities: false)
        send("Run a long task", in: app)
        XCTAssertTrue(button("chat.stop", in: app).waitForExistence(timeout: 10))
        sleep(4)
        XCUIDevice.shared.press(.home)
        XCTAssertFalse(springboard.descendants(matching: .any)["replyActivity.status"].firstMatch.waitForExistence(timeout: 5))
        app.activate()
        button("chat.stop", in: app).tap()
        XCTAssertTrue(app.staticTexts["chat.reply.stopped"].waitForExistence(timeout: 10))
    }

    @MainActor
    private func launch(liveActivities: Bool) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-hermes.address", address, "-hermes.liveActivities", liveActivities ? "YES" : "NO",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["ORBIT_LIVE_ACTIVITY_DELAY"] = "2"
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
    private func send(_ text: String, in app: XCUIApplication) {
        let field = app.descendants(matching: .any)["chat.composer"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText(text)
        let send = button("chat.send", in: app)
        XCTAssertTrue(send.isEnabled)
        send.tap()
    }

    @MainActor
    private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
