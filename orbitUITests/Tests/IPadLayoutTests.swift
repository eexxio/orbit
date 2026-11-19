import XCTest
import UIKit

final class IPadLayoutTests: XCTestCase {
    private struct TurnCounts: Decodable {
        let connections: Int
        let prompts: Int
        let interrupts: Int
    }

    private let fixtureID = UUID()
    private var address: String { "http://127.0.0.1:18765/\(fixtureID)" }

    @MainActor
    func testSidebarKeepsSelectionWhenRotating() async throws {
        let app = try await launch(.portrait)
        let projects = row("pinned", in: app)
        projects.tap()
        XCTAssertTrue(app.navigationBars["Project notes"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Next steps"].waitForExistence(timeout: 10))
        XCTAssertTrue(row("fixture", in: app).isHittable)
        screenshot("ipad-portrait")

        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.navigationBars["Project notes"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Next steps"].exists)
        XCTAssertTrue(row("fixture", in: app).isHittable)
        screenshot("ipad-landscape")
        row("fixture", in: app).tap()
        XCTAssertTrue(app.navigationBars["Research ideas"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Research summary"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testHardwareShortcutsAndOverlay() async throws {
        let app = try await launch(.landscapeLeft)
        row("pinned", in: app).tap()
        XCTAssertTrue(app.navigationBars["Project notes"].waitForExistence(timeout: 10))

        app.typeKey("/", modifierFlags: .command)
        let done = app.buttons["chats.shortcuts.done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["New Chat"].exists)
        screenshot("ipad-keyboard-shortcuts")
        done.tap()
        XCTAssertTrue(done.waitForNonExistence(timeout: 5))

        app.typeKey("n", modifierFlags: .command)
        let composer = app.descendants(matching: .any)["chat.composer"].firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["New Chat"].exists)

        app.typeKey("f", modifierFlags: .command)
        let search = app.textFields["chats.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        app.typeKey("w", modifierFlags: [])
        XCTAssertTrue(row("pinned", in: app).waitForNonExistence(timeout: 5))
        XCTAssertTrue(row("older", in: app).exists)
    }

    @MainActor
    func testCommandHoldPanelAppearance() async throws {
        let app = try await launch(.landscapeLeft, previewHoldPanel: true)
        row("pinned", in: app).tap()
        XCTAssertTrue(app.navigationBars["Project notes"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Next steps"].waitForExistence(timeout: 10))
        screenshot("ipad-command-hold-preview")
    }

    @MainActor
    func testOpensAnotherChatInANewWindow() async throws {
        let app = try await launch(.landscapeLeft)
        row("pinned", in: app).tap()
        XCTAssertTrue(app.navigationBars["Project notes"].waitForExistence(timeout: 10))

        row("fixture", in: app).press(forDuration: 0.8)
        let open = app.buttons["chats.open-window"]
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        open.tap()
        XCTAssertTrue(app.navigationBars["Research ideas"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Research summary"].waitForExistence(timeout: 10))
        screenshot("ipad-new-window")
    }

    @MainActor
    func testSameChatKeepsDraftsSeparateAndSharesOneReply() async throws {
        let app = try await launch(.landscapeLeft)
        row("pinned", in: app).tap()
        let composer = app.descendants(matching: .any)["chat.composer"].firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.tap()
        composer.typeText("First window draft")
        app.typeKey("o", modifierFlags: [.command, .option])

        let source = app.windows.containing(NSPredicate(
            format: "identifier == %@ AND value == %@", "chat.composer", "First window draft"
        )).firstMatch
        let other = app.windows.containing(NSPredicate(
            format: "identifier == %@ AND enabled == NO", "chat.send"
        )).firstMatch
        XCTAssertTrue(other.waitForExistence(timeout: 10))
        XCTAssertTrue(other.navigationBars["Project notes"].exists)
        XCTAssertTrue(source.exists)
        let otherComposer = other.descendants(matching: .any)["chat.composer"].firstMatch
        otherComposer.tap()
        otherComposer.typeText("Stop the reply")
        // Typing enables Send, so use the new draft to identify this window.
        let sendingWindow = app.windows.containing(NSPredicate(
            format: "identifier == %@ AND value == %@", "chat.composer", "Stop the reply"
        )).firstMatch
        sendingWindow.buttons["chat.send"].tap()
        try await advanceReply("delta")
        let streaming = source.staticTexts["chat.reply.streaming"]
        XCTAssertTrue(streaming.waitForExistence(timeout: 10))

        app.typeKey("w", modifierFlags: .command)
        let firstDraft = NSPredicate(format: "value == %@", "First window draft")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: firstDraft, object: composer)], timeout: 10),
                       .completed)
        XCTAssertTrue(streaming.exists)
        source.buttons["chat.stop"].tap()
        try await advanceReply("interrupted")
        XCTAssertTrue(app.staticTexts["chat.reply.stopped"].waitForExistence(timeout: 5))
        XCTAssertEqual(composer.value as? String, "First window draft")

        let (data, _) = try await URLSession.shared.data(from: URL(string: address + "/fixture/state")!)
        let counts = try JSONDecoder().decode(TurnCounts.self, from: data)
        XCTAssertEqual(counts.connections, 1)
        XCTAssertEqual(counts.prompts, 1)
        XCTAssertEqual(counts.interrupts, 1)
    }

    private func advanceReply(_ phase: String) async throws {
        var request = URLRequest(url: URL(string: address + "/fixture/stop/" + phase)!)
        request.httpMethod = "POST"
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 204)
    }

    @MainActor
    private func launch(_ orientation: UIDeviceOrientation, previewHoldPanel: Bool = false) async throws -> XCUIApplication {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "Requires an iPad simulator")
        continueAfterFailure = false
        var seed = URLRequest(url: URL(string: address + "/fixture/seed-ipad")!)
        seed.httpMethod = "POST"
        let (_, response) = try await URLSession.shared.data(for: seed)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 204)
        XCUIDevice.shared.orientation = orientation
        let app = XCUIApplication()
        app.launchArguments = ["-hermes.address", address, "-hermes.theme", "light",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        if previewHoldPanel { app.launchArguments.append("-orbit-show-command-panel") }
        app.launch()
        XCTAssertTrue(row("pinned", in: app).waitForExistence(timeout: 10))
        addTeardownBlock { @MainActor in
            app.terminate()
            XCUIDevice.shared.orientation = .portrait
        }
        return app
    }

    @MainActor
    private func row(_ id: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["chats.row." + id].firstMatch
    }

    @MainActor
    private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
