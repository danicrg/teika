import XCTest

/// Dictate (stood in for by an unsaved note made at launch), edit, then Save: the note reaches
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

        // The app opens on the record screen; the unsaved note waits in To review.
        let editor = app.textViews["Note text"]
        let notes = app.buttons["Notes"]
        XCTAssertTrue(notes.waitForExistence(timeout: 10))
        XCTAssertFalse(editor.exists)
        notes.tap()
        XCTAssertTrue(app.staticTexts["To review"].waitForExistence(timeout: 3))
        app.staticTexts["Pick up the bike from the shop."].tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 3))
        XCTAssertEqual(editor.value as? String, "Pick up the bike from the shop.")
        XCTAssertTrue(app.buttons["Discard note"].exists)

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
