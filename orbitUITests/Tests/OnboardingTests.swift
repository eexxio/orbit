import XCTest

final class OnboardingTests: XCTestCase {
    private let fixtureID = UUID()
    private var address: String { "http://127.0.0.1:18765/\(fixtureID)" }

    @MainActor
    func testFirstLaunchConnectsAndOpensFirstChat() {
        let app = launchFirstRun()
        XCTAssertTrue(app.staticTexts["onboarding.welcome"].waitForExistence(timeout: 10))
        screenshot("onboarding-welcome")
        app.buttons["onboarding.start"].tap()

        let connect = app.buttons["onboarding.connect"]
        XCTAssertTrue(connect.waitForExistence(timeout: 5))
        XCTAssertFalse(connect.isEnabled)
        screenshot("onboarding-connect-empty")
        enterAddress(address, in: app)
        XCTAssertTrue(connect.isEnabled)
        connect.tap()

        XCTAssertTrue(app.staticTexts["onboarding.connected"].waitForExistence(timeout: 10))
        sleep(1)
        screenshot("onboarding-connected")
        app.buttons["onboarding.firstChat"].tap()

        XCTAssertTrue(app.descendants(matching: .any)["chat.composer"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["onboarding.welcome"].exists)
        screenshot("onboarding-first-chat")
    }

    @MainActor
    func testUnreachableAddressShowsErrorAndStaysOnConnect() {
        let app = openConnect()
        enterAddress("http://127.0.0.1:9", in: app)
        app.buttons["onboarding.connect"].tap()

        let error = app.descendants(matching: .any)["onboarding.error"].firstMatch
        XCTAssertTrue(error.waitForExistence(timeout: 15))
        XCTAssertTrue(error.label.contains("Couldn't reach 127.0.0.1"), error.label)
        XCTAssertFalse(app.staticTexts["onboarding.connected"].exists)
        XCTAssertTrue(app.buttons["onboarding.connect"].isEnabled)
        screenshot("onboarding-unreachable")

        // Editing the address clears the error.
        let field = app.textFields["onboarding.address"]
        field.tap()
        field.typeText("0")
        XCTAssertFalse(error.exists)
    }

    @MainActor
    func testWrongPasswordShowsErrorAndClearsPassword() {
        let app = openConnect()
        enterAddress("http://127.0.0.1:18765/locked-\(fixtureID)", in: app)
        let username = app.textFields["onboarding.username"]
        username.tap()
        username.typeText("hermes")
        let password = app.secureTextFields["onboarding.password"]
        password.tap()
        password.typeText("wrong")
        app.buttons["onboarding.connect"].tap()

        let error = app.descendants(matching: .any)["onboarding.error"].firstMatch
        XCTAssertTrue(error.waitForExistence(timeout: 10))
        XCTAssertEqual(error.label, "The username or password was rejected.")
        XCTAssertNotEqual(password.value as? String, "•••••")
        XCTAssertTrue(app.buttons["onboarding.connect"].isEnabled)
        screenshot("onboarding-wrong-password")
    }

    @MainActor
    func testForbiddenWithoutCloudflareSuggestsCloudflareAccess() {
        let app = openConnect()
        enterAddress("http://127.0.0.1:18765/blocked-\(fixtureID)", in: app)
        app.buttons["onboarding.connect"].tap()

        let error = app.descendants(matching: .any)["onboarding.error"].firstMatch
        XCTAssertTrue(error.waitForExistence(timeout: 10))
        XCTAssertEqual(error.label, "The server turned orbit away (403).")
        XCTAssertTrue(app.staticTexts["onboarding.cloudflareHint"].exists)
        XCTAssertTrue(app.buttons["onboarding.cloudflare"].exists)
        screenshot("onboarding-cloudflare-hint")
    }

    @MainActor
    func testSetUpLaterShowsEmptyChatsAndReopensConnect() {
        let app = launchFirstRun()
        XCTAssertTrue(app.buttons["onboarding.later"].waitForExistence(timeout: 10))
        app.buttons["onboarding.later"].tap()

        let setUp = app.buttons["chats.empty.setup"]
        XCTAssertTrue(setUp.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["chats.new"].isEnabled)
        screenshot("chats-empty")

        setUp.tap()
        XCTAssertTrue(app.textFields["onboarding.address"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["onboarding.welcome"].exists)
    }

    /// A fresh install: no saved server.
    @MainActor
    private func launchFirstRun() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-hermes.address", "", "-hermes.username", "", "-hermes.cfid", "",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        return app
    }

    @MainActor
    private func openConnect() -> XCUIApplication {
        let app = launchFirstRun()
        XCTAssertTrue(app.buttons["onboarding.start"].waitForExistence(timeout: 10))
        app.buttons["onboarding.start"].tap()
        return app
    }

    @MainActor
    private func enterAddress(_ text: String, in app: XCUIApplication) {
        let field = app.textFields["onboarding.address"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(text)
        XCTAssertEqual(field.value as? String, text)
    }

    @MainActor
    private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
