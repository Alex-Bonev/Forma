import XCTest

/// My Vibes with two seeded vibes (`-seedVibe`, DEBUG only): Home tab, details edit, delete, applying one to a room,
/// and the new-vibe photo step. The AI call is not driven here (backend tests cover /vibe/profile).
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
        XCTAssertTrue(app.buttons["newVibe"].waitForExistence(timeout: 5), "New vibe card comes first")
        XCTAssertTrue(card(app, "Soft Japandi").exists)
        XCTAssertTrue(card(app, "Warm Library").exists)
        saveShot("vibes-tab")

        card(app, "Warm Library").tap()
        let name = app.textFields["vibeName"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        saveShot("vibe-detail")
        app.buttons["vibeMore"].tap()
        XCTAssertTrue(app.staticTexts["DESCRIPTION"].waitForExistence(timeout: 2), "More details shows the description")
        name.tap()
        name.typeText(" II")
        app.buttons["Back to Vibes"].tap()   // edits save on their own
        XCTAssertTrue(card(app, "Warm Library II").waitForExistence(timeout: 5), "rename saved without a Save button")

        card(app, "Warm Library II").tap()
        app.buttons["Delete"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Delete this vibe?"].waitForExistence(timeout: 2))
        saveShot("vibe-delete")
        app.buttons["confirmDelete"].tap()
        XCTAssertTrue(app.buttons["newVibe"].waitForExistence(timeout: 5), "delete returns to the Vibes tab")
        XCTAssertFalse(card(app, "Warm Library").exists)
        XCTAssertTrue(card(app, "Soft Japandi").exists)
    }

    func testApplyVibeToRoom() {
        let app = launch(closeFullscreen: false)   // -demo opens a demo room's Designer
        XCTAssertTrue(app.buttons["roomVibe"].waitForExistence(timeout: 10))
        app.buttons["roomVibe"].tap()
        XCTAssertTrue(app.buttons["vibeOption"].firstMatch.waitForExistence(timeout: 5))
        saveShot("vibe-dropdown")
        XCTAssertFalse(app.buttons["Remove"].exists, "nothing to remove yet")
        // A tap anywhere else closes the dropdown and does nothing else.
        app.otherElements["designer-canvas"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
        XCTAssertFalse(app.buttons["vibeOption"].firstMatch.waitForExistence(timeout: 1), "tap outside closes the menu")
        XCTAssertFalse(app.buttons["Lock"].exists, "and doesn't select anything")
        app.buttons["roomVibe"].tap()
        XCTAssertTrue(app.buttons["vibeOption"].firstMatch.waitForExistence(timeout: 3))
        app.buttons["vibeOption"].firstMatch.tap()
        XCTAssertTrue(app.buttons["roomVibe"].label.hasPrefix("Vibe: "), "pill shows the applied vibe")
    }

    func testNewVibePhotoStep() {
        let app = launch()
        app.buttons["tabVibes"].tap()
        app.buttons["newVibe"].tap()
        XCTAssertTrue(app.staticTexts["Photos you love"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["findVibe"].isEnabled, "no photos yet")
        saveShot("vibe-new")
        app.buttons["Back"].tap()
        XCTAssertTrue(app.buttons["newVibe"].waitForExistence(timeout: 5))
    }
}

/// Writes a screenshot to $SHOT_DIR (pass TEST_RUNNER_SHOT_DIR to xcodebuild) for design review. No-op otherwise.
func saveShot(_ name: String) {
    guard let dir = ProcessInfo.processInfo.environment["SHOT_DIR"] else { return }
    sleep(1)   // let transitions settle
    try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
}
