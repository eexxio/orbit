import XCTest

final class ChatExportTests: XCTestCase {
    @MainActor
    func testSharesMarkdownFromCachedChatWhenServerIsUnavailable() async throws {
        continueAfterFailure = false
        let address = "http://127.0.0.1:18765/export-\(UUID())"
        let exportedFile = exportCopyURL()
        defer { try? FileManager.default.removeItem(at: exportedFile) }
        let app = exportApp(address: address, copyingTo: exportedFile)
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
        let composer = app.descendants(matching: .any)["chat.composer"].firstMatch
        let draft = "This draft must stay private."
        composer.tap()
        composer.typeText(draft)
        XCTAssertEqual(composer.value as? String, draft)
        export.tap()

        let saveToFiles = app.cells["Save to Files"]
        XCTAssertTrue(saveToFiles.waitForExistence(timeout: 10))
        let filename = app.descendants(matching: .any)["LP.CaptionBar.TopCaption"]
        XCTAssertTrue(filename.exists)
        XCTAssertEqual(filename.label, "Weekend in Brașov 1.md")
        screenshot("chat-export-share-sheet")

        let contents = try Data(contentsOf: exportedFile)
        let expected = """
            # Weekend in Brașov #1

            This export includes the messages available in orbit at the time of export.

            ## You

            Show me a Swift greeting.

            ## Assistant

            ⚠️ Here is a Swift greeting:

            ```swift
            print("Bună!")
            ```

            More in the [Swift docs](https://swift.org/).

            | A | B |
            | - | - |
            | 1 | 2 |

            """
        XCTAssertEqual(contents, Data(expected.utf8), String(decoding: contents, as: UTF8.self))

        saveToFiles.tap()
        let save = app.buttons["DOCPicker.actionButton"]
        XCTAssertTrue(save.waitForExistence(timeout: 10))
        let local = app.otherElements["DOC.browsingRoot Source: com.apple.FileProvider.LocalStorage, Title: On My iPhone"]
        if !local.exists {
            app.buttons["BackButton"].tap()
            app.staticTexts["On My iPhone"].tap()
        }
        XCTAssertTrue(local.waitForExistence(timeout: 5))
        save.tap()
        let replace = app.alerts.buttons["Replace"]
        if replace.waitForExistence(timeout: 2) { replace.tap() }
        XCTAssertTrue(save.waitForNonExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["LOADING"].exists)

        let files = XCUIApplication(bundleIdentifier: "com.apple.DocumentsApp")
        files.launch()
        let recents = files.buttons["Recents"].firstMatch
        XCTAssertTrue(recents.waitForExistence(timeout: 10))
        recents.tap()
        let saved = files.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH[cd] %@", "Weekend in Brașov 1")).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 10))
        screenshot("chat-export-saved-in-files")
    }

    @MainActor
    func testStoppedUntitledChatExportsAnAssistantSectionWithoutReplyText() throws {
        continueAfterFailure = false
        let exportedFile = exportCopyURL()
        defer { try? FileManager.default.removeItem(at: exportedFile) }
        let app = exportApp(address: "http://127.0.0.1:18765/\(UUID())", copyingTo: exportedFile)
        app.launch()

        let newChat = app.buttons["chats.new"]
        XCTAssertTrue(newChat.waitForExistence(timeout: 10))
        newChat.tap()
        let composer = app.descendants(matching: .any)["chat.composer"].firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        composer.tap()
        composer.typeText("Stop while waiting")
        XCTAssertEqual(composer.value as? String, "Stop while waiting")
        app.buttons["chat.send"].tap()
        XCTAssertTrue(app.staticTexts["chat.reply.waiting"].waitForExistence(timeout: 10))
        app.buttons["chat.stop"].tap()
        XCTAssertTrue(app.staticTexts["chat.reply.stopped"].waitForExistence(timeout: 10))

        app.buttons["chat.export.markdown"].tap()
        let filename = app.descendants(matching: .any)["LP.CaptionBar.TopCaption"]
        XCTAssertTrue(filename.waitForExistence(timeout: 10))
        XCTAssertEqual(filename.label, "orbit chat.md")
        let contents = try String(contentsOf: exportedFile, encoding: .utf8)
        XCTAssertEqual(contents, """
            # orbit chat

            This export includes the messages available in orbit at the time of export.

            *The latest reply was stopped.*

            ## You

            Stop while waiting

            ## Assistant

            *Stopped*

            """)
    }

    private func exportCopyURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).md")
    }

    @MainActor
    private func exportApp(address: String, copyingTo file: URL) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-hermes.address", address, "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-uiTest.markdownExportPath", file.path,
        ]
        return app
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
