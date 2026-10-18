import XCTest

/// My Vibes with two seeded vibes (`-seedVibe`, DEBUG only): Home tab, details edit, delete, and applying one to a
/// room. The photo picker and the AI call are not driven here (backend tests cover /vibe/profile).
final class VibeFlowTests: XCTestCase {
    private func launch(closeFullscreen: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-seedVibe"]
        app.launch()
        if closeFullscreen { app.buttons["Close fullscreen"].tap() }   // -demo opens the Designer straight from Home
        return app
    }

    private func card(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
    }

    func testVibesTabEditAndDelete() {
        let app = launch()
        app.buttons["tabVibes"].tap()
        XCTAssertTrue(app.buttons["newVibe"].waitForExistence(timeout: 5), "+ Vibe card comes first")
        XCTAssertTrue(card(app, "Soft Japandi").exists)
        XCTAssertTrue(card(app, "Warm Library").exists)

        card(app, "Warm Library").tap()
        let name = app.textFields["vibeName"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["saveChanges"].isEnabled, "nothing edited yet")
        name.tap()
        name.typeText(" II")
        XCTAssertTrue(app.buttons["saveChanges"].isEnabled)
        app.buttons["saveChanges"].tap()

        app.buttons["deleteVibe"].tap()
        XCTAssertTrue(app.staticTexts["Delete this vibe?"].waitForExistence(timeout: 2))
        app.buttons["confirmDelete"].tap()
        XCTAssertTrue(app.buttons["newVibe"].waitForExistence(timeout: 5), "delete returns to the Vibes tab")
        XCTAssertFalse(card(app, "Warm Library").exists)
        XCTAssertTrue(card(app, "Soft Japandi").exists)
    }

    func testApplyVibeToRoom() {
        let app = launch(closeFullscreen: false)   // -demo opens a demo room's Designer
        XCTAssertTrue(app.buttons["roomVibe"].waitForExistence(timeout: 10))
        app.buttons["roomVibe"].tap()
        XCTAssertTrue(app.buttons["applyVibe"].waitForExistence(timeout: 5))
        app.buttons["applyVibe"].tap()
        XCTAssertTrue(app.buttons["roomVibe"].label.hasPrefix("Vibe: "), "pill shows the applied vibe")
    }
}
