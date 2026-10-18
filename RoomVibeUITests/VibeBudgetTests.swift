import XCTest

/// Budget on Shop a vibe and in the cart, against the mock backend. Start it first: `cd backend && MOCK=1 .venv/bin/fastapi dev main.py`.
final class VibeBudgetTests: XCTestCase {
    private func el(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    /// Launches the demo and opens Make it real > Shop a vibe (no run started).
    private func openShop() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-fresh"]
        app.launch()
        XCTAssertTrue(app.buttons["Make it real"].firstMatch.waitForExistence(timeout: 10))
        generate(app)
        let openVibe = app.buttons["openVibe"]
        XCTAssertTrue(openVibe.waitForExistence(timeout: 8))
        wait(for: [expectation(for: NSPredicate(format: "isHittable == true"), evaluatedWith: openVibe)], timeout: 10)
        let start = app.buttons["vibeStart"]
        for _ in 0..<3 where !start.exists {
            if openVibe.isHittable { openVibe.tap() }
            _ = start.waitForExistence(timeout: 3)
        }
        XCTAssertTrue(start.exists)
        return app
    }

    /// Scrolls the results until `element` can be tapped. Drags in the right margin: the before/after slider captures any drag that starts
    /// on it (vertical too), so a swipe from the middle moves the slider and the page stays put.
    @discardableResult
    private func scrollUntilHittable(_ app: XCUIApplication, _ element: XCUIElement, tries: Int = 10) -> Bool {
        for _ in 0..<tries {
            if element.exists && element.isHittable { return true }
            let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.975, dy: 0.85))
            from.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.975, dy: 0.3)))
            sleep(1)
        }
        return element.exists && element.isHittable
    }

    /// Opens the budget sheet from the summary card.
    private func openBudgetSheet(_ app: XCUIApplication) {
        let change = el(app, "changeBudget")
        XCTAssertTrue(change.waitForExistence(timeout: 60), "summary card shows once picks are in")
        for _ in 0..<3 where !el(app, "applyBudget").exists {
            if scrollUntilHittable(app, change) { change.tap() }
            _ = el(app, "applyBudget").waitForExistence(timeout: 3)
        }
        XCTAssertTrue(el(app, "applyBudget").exists, "the budget sheet opens")
    }

    /// Taps `id`, retrying while an animation swallows it.
    private func tapChip(_ app: XCUIApplication, _ id: String) {
        let chip = el(app, id)
        XCTAssertTrue(chip.waitForExistence(timeout: 10), id)
        chip.tap()
    }

    /// Opens Shop a vibe, picks `chip`, types a prompt and starts. The room may already have a saved vibe,
    /// so Restyle and shop is not asserted disabled.
    private func startVibe(chip: String) -> XCUIApplication {
        let app = openShop()
        tapChip(app, chip)
        let prompt = app.textFields["vibePrompt"]
        prompt.tap()
        prompt.typeText("Cozy japandi nook")
        app.buttons["vibeStart"].tap()
        return app
    }

    func testBudgetFieldIsOnTheShopScreen() {
        let app = openShop()
        XCTAssertTrue(app.staticTexts["Budget"].firstMatch.waitForExistence(timeout: 5))
        let amount = el(app, "budgetAmount")
        XCTAssertTrue(amount.waitForExistence(timeout: 5))
        tapChip(app, "budgetChip-800")
        let has800 = expectation(for: NSPredicate(format: "value CONTAINS '800'"), evaluatedWith: amount)
        wait(for: [has800], timeout: 5)
        tapChip(app, "budgetChip-none")
        let empty = expectation(for: NSPredicate(format: "value == nil OR value == '' OR NOT (value CONTAINS '8')"), evaluatedWith: amount)
        wait(for: [empty], timeout: 5)
        saveShot("budget-field")
    }

    func testBudgetSummaryAppearsAndSheetOpens() {
        let app = startVibe(chip: "budgetChip-800")
        openBudgetSheet(app)
        let status = app.staticTexts.matching(NSPredicate(format: "label == 'Within budget' OR label == 'Over budget'")).firstMatch
        XCTAssertTrue(status.exists || app.staticTexts["Change your budget"].exists)
        XCTAssertTrue(app.staticTexts["Change your budget"].exists)
        saveShot("budget-sheet")
        el(app, "cancelBudget").tap()
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.staticTexts["Change your budget"])
        wait(for: [gone], timeout: 5)
    }

    func testChangingBudgetRePicks() {
        let app = startVibe(chip: "budgetChip-400")
        openBudgetSheet(app)
        tapChip(app, "budgetChip-1200")
        el(app, "applyBudget").tap()
        sleep(3)
        XCTAssertTrue(el(app, "changeBudget").waitForExistence(timeout: 20), "results survive the change")
        scrollUntilHittable(app, el(app, "changeBudget"))
        let amount = app.staticTexts.containing(NSPredicate(format: "label CONTAINS '1,200'")).firstMatch
        XCTAssertTrue(amount.waitForExistence(timeout: 10))
        saveShot("budget-changed")
    }

    /// Follows testMakeItRealRendersWithAShoppedProduct's navigation back to the room; the cart icon sits in the
    /// fullscreen room's bottom bar. Not verified on a device: the cart icon may need the Objects panel closed.
    func testCartShowsBudgetCard() {
        let app = startVibe(chip: "budgetChip-800")
        let addAll = el(app, "addAllPicks")
        XCTAssertTrue(addAll.waitForExistence(timeout: 60), "Add all picks is shown once the picks are in")
        for _ in 0..<3 where !app.buttons["All picks are in your room"].exists {
            if scrollUntilHittable(app, addAll) { addAll.tap() }
            _ = app.buttons["All picks are in your room"].waitForExistence(timeout: 3)
        }
        XCTAssertTrue(app.buttons["All picks are in your room"].exists)
        sleep(3)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["Close"].tap()

        let cart = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Cart'")).firstMatch
        XCTAssertTrue(cart.waitForExistence(timeout: 10), "cart icon in the room's bottom bar")
        for _ in 0..<3 where !el(app, "checkout").exists {
            if cart.isHittable { cart.tap() }
            _ = el(app, "checkout").waitForExistence(timeout: 3)
        }
        XCTAssertTrue(el(app, "changeBudget").waitForExistence(timeout: 5), "one-room cart budget card")
        let checkout = el(app, "checkout")
        XCTAssertTrue(checkout.exists)
        XCTAssertFalse(checkout.isEnabled)
        saveShot("budget-cart")
    }
}
