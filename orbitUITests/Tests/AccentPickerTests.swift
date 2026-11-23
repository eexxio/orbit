import XCTest

final class AccentPickerTests: XCTestCase {
    @MainActor
    func testAccentSelectionSlides() {
        checkSelection(reduceMotion: false)
    }

    @MainActor
    func testAccentSelectionCrossfadesWithReduceMotion() {
        checkSelection(reduceMotion: true)
    }

    @MainActor
    private func checkSelection(reduceMotion: Bool) {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-hermes.address", "http://127.0.0.1:18765/\(UUID())",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        if reduceMotion { app.launchArguments.append("-uitest-reduce-motion") }
        app.launch()
        let settings = button("chats.settings", in: app)
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()
        app.swipeUp()
        let old = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND selected == true", "appearance.accent.")).firstMatch
        XCTAssertTrue(old.waitForExistence(timeout: 5))
        if !old.isHittable { app.swipeUp() }
        let oldIdentifier = old.identifier
        let new = button(oldIdentifier == "appearance.accent.teal" ? "appearance.accent.mono" : "appearance.accent.teal", in: app)
        XCTAssertTrue(old.isSelected)
        XCTAssertFalse(new.isSelected)
        let mode = reduceMotion ? "crossfade" : "slide"
        screenshot("\(mode)-before")
        Thread.sleep(forTimeInterval: 3)
        new.tap()
        Thread.sleep(forTimeInterval: 3)
        for frame in 0..<5 {
            screenshot("\(mode)-frame-\(frame)")
            Thread.sleep(forTimeInterval: 0.03)
        }
        XCTAssertTrue(new.isSelected)
        XCTAssertFalse(button(oldIdentifier, in: app).isSelected)
        new.tap()
        XCTAssertTrue(new.isSelected)
        XCTAssertFalse(button(oldIdentifier, in: app).isSelected)
    }

    @MainActor
    private func button(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier == %@", identifier)).firstMatch
    }

    @MainActor
    private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
