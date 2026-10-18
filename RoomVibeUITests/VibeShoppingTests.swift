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
        XCTAssertTrue(app.otherElements["shopRow-0-sofa"].waitForExistence(timeout: 10))
        let badge = app.staticTexts["Fits budget"].firstMatch
        XCTAssertTrue(badge.waitForExistence(timeout: 20), "the budget pick should be marked once every agent is done")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'of your $800'")).firstMatch.exists)

        // Add the first product to the room; the Designer underneath lists it once the sheet closes.
        let addButton = app.buttons["Add to room"].firstMatch
        XCTAssertTrue(addButton.waitForExistence(timeout: 5))
        if !addButton.isHittable { app.swipeUp() }
        addButton.tap()
        XCTAssertTrue(app.buttons["Added to room"].firstMatch.waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["Close"].tap()
        if !app.buttons["Add object"].waitForExistence(timeout: 3) { app.buttons["Objects"].tap() }
        XCTAssertTrue(app.staticTexts["Sofa"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts.matching(identifier: "Sofa").count, 2, "the demo sofa plus the shopped one")

        // The shopped sofa is listed first (placements before scanned furniture) and links to its product.
        app.staticTexts["Sofa"].firstMatch.tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Open product'")).firstMatch.waitForExistence(timeout: 3))

        // SAM 3D (mock): the catalog stand-in becomes a model named after the product, still selected.
        let make3D = app.buttons["Make it 3D (beta)"]
        XCTAssertTrue(make3D.waitForExistence(timeout: 3))
        make3D.tap()
        // Installed = the catalog "Sofa" row is renamed after the product, leaving only the demo room's scanned Sofa.
        // (The label flips to "Making 3D…" first, so waiting for the button to go away is not enough.)
        let installed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.staticTexts.matching(identifier: "Sofa").count == 1 || app.buttons["3D failed, try again"].exists
        }, object: nil)
        wait(for: [installed], timeout: 20)
        XCTAssertFalse(app.buttons["3D failed, try again"].exists, "the mock model should load")
        XCTAssertEqual(app.staticTexts.matching(identifier: "Sofa").count, 1)
        XCTAssertGreaterThanOrEqual(app.staticTexts.matching(identifier: "Linen Low Sofa 1").count, 1)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "vibe-shopping"
        shot.lifetime = .keepAlways
        add(shot)
        app.buttons["Remove"].tap()   // the demo room persists across launches; leave it as other tests expect
        XCTAssertEqual(app.staticTexts.matching(identifier: "Sofa").count, 1)
        XCTAssertEqual(app.staticTexts.matching(identifier: "Linen Low Sofa 1").count, 0)

        // The 3D model also went into the object library: delete it there (Home, long-press, Delete).
        app.buttons["Close fullscreen"].tap()
        let tile = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Linen Low Sofa 1")).firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 5))
        tile.press(forDuration: 1.0)
        app.buttons["Delete"].tap()
        let deleted = NSPredicate(format: "exists == false")
        expectation(for: deleted, evaluatedWith: tile)
        waitForExpectations(timeout: 5)
    }
}
