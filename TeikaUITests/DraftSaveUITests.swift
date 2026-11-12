import XCTest

/// Dictate (stood in for by a draft saved at launch), edit, then Save: the note reaches
/// the vault folder only at that point. Uses the DEBUG vault override, so it needs the
/// Simulator and a writable folder; it skips itself elsewhere.
final class DraftSaveUITests: XCTestCase {
    func testEditThenSaveWritesTheNoteToTheVault() throws {
        let vault = ProcessInfo.processInfo.environment["TEIKA_UI_TEST_VAULT"] ?? "/tmp/teika-ui-vault"
        let app = XCUIApplication()
        app.launchArguments += [
            "-taskExportApp", "off",
            "-teika-debug-vault", vault,
            "-teika-debug-note", "Pick up the bike from the shop.",
        ]
        app.launch()

        let editor = app.textViews["Note text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        XCTAssertEqual(editor.value as? String, "Pick up the bike from the shop.")
        XCTAssertTrue(app.buttons["Discard note"].exists)

        // It also waits in the library's To review section, and opens back here from it.
        app.buttons["Notes"].tap()
        XCTAssertTrue(app.staticTexts["To review"].waitForExistence(timeout: 3))
        app.staticTexts["Pick up the bike from the shop."].tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 3))

        // Just past the end of the first line, where a thumb would put the cursor.
        editor.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.0))
            .withOffset(CGVector(dx: 0, dy: 22)).tap()
        editor.typeText(" Before six.")
        XCTAssertEqual(editor.value as? String, "Pick up the bike from the shop. Before six.")

        app.buttons["Save to Obsidian"].tap()
        // The screen clears for the next note once the file is written.
        let cleared = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: editor)
        wait(for: [cleared], timeout: 5)
        XCTAssertFalse(app.buttons["Discard note"].exists)
    }
}
