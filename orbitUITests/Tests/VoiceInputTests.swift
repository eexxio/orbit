import XCTest

final class VoiceInputTests: XCTestCase {
    private let address = "http://127.0.0.1:18765/\(UUID())"

    @MainActor
    func testDictationAppendsWithoutSendingAndReplyCanBeRead() {
        let app = launch(readAloud: "unrecognized-mode")
        let newChat = app.buttons["chats.new"]
        XCTAssertTrue(newChat.waitForExistence(timeout: 10))
        newChat.tap()

        let mic = app.buttons["chat.dictate"]
        let stop = app.buttons["chat.dictate.stop"]
        let send = app.buttons["chat.send"]
        let draft = app.descendants(matching: .any)["chat.composer"].firstMatch
        XCTAssertTrue(mic.waitForExistence(timeout: 10))
        XCTAssertFalse(send.isEnabled)
        screenshot("voice-composer-idle")

        draft.tap()
        draft.typeText("Send")
        mic.tap()
        XCTAssertTrue(stop.waitForExistence(timeout: 5))
        XCTAssertEqual(stop.value as? String, "Listening")
        XCTAssertEqual(draft.value as? String, "Send after reconnecting")
        XCTAssertFalse(app.staticTexts["Send after reconnecting"].exists)
        screenshot("voice-composer-listening")

        stop.tap()
        XCTAssertTrue(mic.waitForExistence(timeout: 5))
        XCTAssertEqual(draft.value as? String, "Send after reconnecting")
        XCTAssertTrue(send.isEnabled)
        screenshot("voice-composer-dictated")

        send.tap()
        let speak = app.buttons["chat.reply.speak"]
        XCTAssertTrue(speak.waitForExistence(timeout: 10))
        let copy = app.buttons["chat.reply.completed"]
        XCTAssertEqual(copy.frame.width, 44, accuracy: 1)
        XCTAssertEqual(copy.frame.height, 44, accuracy: 1)
        XCTAssertEqual(speak.frame.size, copy.frame.size)
        XCTAssertEqual(speak.label, "Read reply aloud")
        speak.tap()
        XCTAssertEqual(speak.label, "Stop reading")
        XCTAssertTrue(speak.isEnabled)
        screenshot("voice-reply-reading")
        speak.tap()
        XCTAssertEqual(speak.label, "Read reply aloud")
    }

    @MainActor
    func testStalledReadAloudResetsButtonAndShowsAnInlineNotice() {
        let app = launch(stallReadAloud: true)
        let newChat = app.buttons["chats.new"]
        XCTAssertTrue(newChat.waitForExistence(timeout: 10))
        newChat.tap()

        let draft = app.descendants(matching: .any)["chat.composer"].firstMatch
        XCTAssertTrue(draft.waitForExistence(timeout: 5))
        draft.tap()
        draft.typeText("Send after reconnecting")
        app.buttons["chat.send"].tap()

        let speak = app.buttons["chat.reply.speak"]
        XCTAssertTrue(speak.waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["chat.reply.speak.error"].exists)
        speak.tap()
        XCTAssertEqual(speak.label, "Stop reading")

        let notice = app.staticTexts["chat.reply.speak.error"]
        XCTAssertTrue(notice.waitForExistence(timeout: 8))
        XCTAssertEqual(notice.label, "Couldn’t read this reply aloud.")
        XCTAssertEqual(speak.label, "Read reply aloud")
        screenshot("voice-reply-reading-error")
    }

    @MainActor
    func testUnknownReadAloudPreferenceShowsOff() {
        let app = launch(readAloud: "unrecognized-mode")
        XCTAssertEqual(readAloudPicker(in: app).value as? String, "Off")
        screenshot("voice-read-aloud-settings")
    }

    @MainActor
    func testReadAloudPreferencePersists() {
        let app = launch()
        let picker = readAloudPicker(in: app)
        if picker.value as? String != "Off" { select("off", using: picker, in: app) }
        XCTAssertEqual(picker.value as? String, "Off")
        select("afterVoice", using: picker, in: app)
        XCTAssertEqual(picker.value as? String, "After voice")
        screenshot("voice-read-aloud-after-voice")

        app.terminate()
        app.launch()
        let reopened = readAloudPicker(in: app)
        XCTAssertEqual(reopened.value as? String, "After voice")
        select("off", using: reopened, in: app)
        XCTAssertEqual(reopened.value as? String, "Off")
    }

    @MainActor
    private func launch(readAloud: String? = nil, stallReadAloud: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "-hermes.address", address, "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-orbitFakeDictation", "after reconnecting",
            stallReadAloud ? "-orbitStallReadAloud" : "-orbitFakeReadAloud",
        ]
        if let readAloud { app.launchArguments += ["-hermes.readAloud", readAloud] }
        app.launch()
        return app
    }

    @MainActor
    private func readAloudPicker(in app: XCUIApplication) -> XCUIElement {
        let settings = app.buttons["chats.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()
        let picker = app.buttons["settings.readAloud"]
        for _ in 0..<4 where !picker.isHittable { app.swipeUp() }
        XCTAssertTrue(picker.isHittable)
        return picker
    }

    @MainActor
    private func select(_ option: String, using picker: XCUIElement, in app: XCUIApplication) {
        picker.tap()
        let item = app.buttons["settings.readAloud.\(option)"]
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        item.tap()
    }

    @MainActor
    private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
