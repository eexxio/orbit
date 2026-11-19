import XCTest

final class ChatExportTests: XCTestCase {
    @MainActor
    func testSharesMarkdownFromCachedChatWhenServerIsUnavailable() async throws {
        continueAfterFailure = false
        let address = "http://127.0.0.1:18765/export-\(UUID())"
        let app = XCUIApplication()
        app.launchArguments = ["-hermes.address", address, "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        openChat(in: app)

        app.terminate()
        var request = URLRequest(url: URL(string: "\(address)/fixture/offline")!, timeoutInterval: 5)
        request.httpMethod = "POST"
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 204)

        app.launch()
        openChat(in: app)
        let export = app.buttons["chat.export.markdown"]
        XCTAssertTrue(export.waitForExistence(timeout: 5))
        screenshot("chat-export-button")
        export.tap()

        let saveToFiles = app.cells["Save to Files"]
        XCTAssertTrue(saveToFiles.waitForExistence(timeout: 10))
        let filename = app.descendants(matching: .any)["LP.CaptionBar.TopCaption"]
        XCTAssertTrue(filename.exists)
        XCTAssertEqual(filename.label, "Weekend in Brașov 1.md")
        screenshot("chat-export-share-sheet")
    }

    @MainActor
    private func openChat(in app: XCUIApplication) {
        let chat = app.staticTexts["Weekend in Brașov #1"]
        XCTAssertTrue(chat.waitForExistence(timeout: 10))
        chat.tap()
        XCTAssertTrue(app.staticTexts["⚠️ Here is a Swift greeting:"].waitForExistence(timeout: 10))
    }

    @MainActor
    private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
