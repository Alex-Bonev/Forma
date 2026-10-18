import XCTest

/// Vibe shopping against the mock backend. Start it first: `cd backend && MOCK=1 .venv/bin/fastapi dev main.py`.
final class VibeShoppingTests: XCTestCase {
    func testPromptStreamsProductsWithinBudget() {
        let app = XCUIApplication()
        app.launchArguments = ["-demo"]
        app.launch()

        let makeItReal = app.buttons["Make it real"]
        XCTAssertTrue(makeItReal.waitForExistence(timeout: 10))
        makeItReal.firstMatch.tap()
        let openVibe = app.buttons["openVibe"]
        XCTAssertTrue(openVibe.waitForExistence(timeout: 10))
        let start = app.buttons["vibeStart"]
        // The render sheet may still be animating in, which can swallow the first tap.
        for _ in 0..<3 where !start.exists {
            openVibe.tap()
            _ = start.waitForExistence(timeout: 3)
        }
        XCTAssertTrue(start.exists)
        XCTAssertFalse(start.isEnabled, "nothing to analyze yet")
        let prompt = app.textFields["vibePrompt"]
        prompt.tap()
        prompt.typeText("Cozy japandi nook under $800")
        start.tap()

        // Mock: half the agents finish on the first poll, the rest one poll (4 s) later.
        XCTAssertTrue(app.staticTexts["Warm Japandi"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.otherElements["shopRow-sofa"].waitForExistence(timeout: 10))
        let badge = app.staticTexts["Fits budget"].firstMatch
        XCTAssertTrue(badge.waitForExistence(timeout: 20), "the budget pick should be marked once every agent is done")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'of your $800'")).firstMatch.exists)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "vibe-shopping"
        shot.lifetime = .keepAlways
        add(shot)
    }
}
