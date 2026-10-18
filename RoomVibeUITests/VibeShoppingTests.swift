import XCTest

/// Vibe shopping against the mock backend. Start it first: `cd backend && MOCK=1 .venv/bin/fastapi dev main.py`.
final class VibeShoppingTests: XCTestCase {
    /// Launches the demo, opens Make it real > Shop a vibe, and starts a run for `text`.
    private func startVibe(_ text: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-demo"]
        app.launch()

        let makeItReal = app.buttons["Make it real"].firstMatch
        XCTAssertTrue(makeItReal.waitForExistence(timeout: 10))
        let openVibe = app.buttons["openVibe"]
        // A tap during launch (the Designer still settling) can be swallowed: retry until the render sheet opens.
        generate(app)
        _ = openVibe.waitForExistence(timeout: 8)
        XCTAssertTrue(openVibe.exists)
        let start = app.buttons["vibeStart"]
        // The render sheet may still be animating in, which can swallow the first tap.
        let hittable = expectation(for: NSPredicate(format: "isHittable == true"), evaluatedWith: openVibe)
        wait(for: [hittable], timeout: 10)   // exists while still sliding in offscreen; tapping then fails hard
        for _ in 0..<3 where !start.exists {
            if openVibe.isHittable { openVibe.tap() }
            _ = start.waitForExistence(timeout: 3)
        }
        XCTAssertTrue(start.exists)
        XCTAssertFalse(start.isEnabled, "nothing to analyze yet")
        let prompt = app.textFields["vibePrompt"]
        prompt.tap()
        prompt.typeText(text)
        start.tap()
        return app
    }

    /// "Add all" drops every pick into the room at once; the Designer spreads them over free floor.
    func testAddAllPicksPutsTheSetInTheRoom() {
        let app = startVibe("Cozy japandi nook")   // no budget: the picks are each item's first product
        let addAll = app.buttons["addAllPicks"]
        XCTAssertTrue(addAll.waitForExistence(timeout: 20), "shown once every agent is done")
        XCTAssertEqual(addAll.label, "Add all 4 picks to room")
        addAll.tap()
        XCTAssertTrue(app.buttons["All picks are in your room"].waitForExistence(timeout: 5))
        XCTAssertFalse(addAll.isEnabled)
        XCTAssertEqual(app.buttons.matching(identifier: "Added to room").count, 4)

        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["Close"].tap()
        openObjectsPanel(app)
        let names = ["Sofa", "Round Table", "Armchair", "Floor Lamp"]
        for name in names { XCTAssertTrue(app.staticTexts[name].firstMatch.waitForExistence(timeout: 5), name) }
        app.buttons["Objects"].tap()   // panel away: the room shows where the new items landed
        sleep(2)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "vibe-add-all"
        shot.lifetime = .keepAlways
        add(shot)
        openObjectsPanel(app)

        // The demo room persists across launches: remove the shopped items (listed before scanned furniture).
        for name in names {
            openObjectsPanel(app)   // Remove closes the sheet
            app.staticTexts[name].firstMatch.tap()
            XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Open product'")).firstMatch.waitForExistence(timeout: 3),
                          "\(name) should be the shopped one")
            removeSelected(app)
        }
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Open product'")).firstMatch.exists)
    }

    /// Plan -> place -> Make it real: a shopped product goes to /render with its photo (mock echoes the snapshot).
    func testMakeItRealRendersWithAShoppedProduct() {
        let app = startVibe("Cozy japandi nook")
        let addButton = app.buttons["Add to room"].firstMatch, added = app.buttons["Added to room"].firstMatch
        XCTAssertTrue(addButton.waitForExistence(timeout: 20))
        // A tap while the list is still scrolling can miss: retry until the card says Added.
        for _ in 0..<3 where !added.exists {
            if !addButton.isHittable { app.swipeUp(); sleep(1) }
            if addButton.isHittable { addButton.tap() }
            _ = added.waitForExistence(timeout: 3)
        }
        XCTAssertTrue(added.exists)
        sleep(3)   // the listing photo is cached in the background (ProductPhotos)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["Close"].tap()

        generate(app)
        XCTAssertTrue(app.buttons["Image"].waitForExistence(timeout: 30), "the render should finish")
        XCTAssertFalse(app.staticTexts["Couldn't render"].exists)
        app.buttons["Close"].tap()

        // The demo room persists across launches: remove the shopped sofa again.
        openObjectsPanel(app)
        sleep(1)   // the panel slides in: a tap mid-slide can land on the row's eye button instead
        app.staticTexts["Sofa"].firstMatch.tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Open product'")).firstMatch.waitForExistence(timeout: 3))
        removeSelected(app)
    }

    func testPromptStreamsProductsWithinBudget() {
        let app = startVibe("Cozy japandi nook under $800")

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
        sleep(1)
        if !app.staticTexts["Sofa"].exists { app.buttons["Objects"].tap() }   // open the Objects panel
        XCTAssertTrue(app.staticTexts["Sofa"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts.matching(identifier: "Sofa").count, 2, "the demo sofa plus the shopped one")

        // The shopped sofa is listed first (placements before scanned furniture) and links to its product.
        app.staticTexts["Sofa"].firstMatch.tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Open product'")).firstMatch.waitForExistence(timeout: 3))

        // SAM 3D (mock): the catalog stand-in becomes a model named after the product, still selected.
        let make3D = app.buttons["Make it 3D (beta)"]
        XCTAssertTrue(make3D.waitForExistence(timeout: 3))
        make3D.tap()
        // Installed = the selection card's title becomes the product's name.
        // (The label flips to "Making 3D…" first, so waiting for the button to go away is not enough.)
        let installed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.staticTexts["Linen Low Sofa 1"].exists || app.buttons["3D failed, try again"].exists
        }, object: nil)
        wait(for: [installed], timeout: 20)
        XCTAssertFalse(app.buttons["3D failed, try again"].exists, "the mock model should load")
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "vibe-shopping"
        shot.lifetime = .keepAlways
        add(shot)
        removeSelected(app)   // the demo room persists across launches; leave it as other tests expect
        XCTAssertEqual(app.staticTexts.matching(identifier: "Sofa").count, 1)
        XCTAssertEqual(app.staticTexts.matching(identifier: "Linen Low Sofa 1").count, 0)

        // The 3D model also went into the object library: delete it there (Home, long-press, Delete).
        app.buttons["Close fullscreen"].tap()
        app.openObjectsTab()
        let tile = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Linen Low Sofa 1")).firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 5))
        tile.press(forDuration: 1.0)
        app.buttons["Delete"].tap()
        let deleted = NSPredicate(format: "exists == false")
        expectation(for: deleted, evaluatedWith: tile)
        waitForExpectations(timeout: 5)
    }

    /// A room's run outlives the screen and the app: leaving and reopening shows it as is, and after a relaunch the
    /// saved restyle and picks come back without running again.
    func testShopRunPersists() {
        let app = startVibe("Cozy japandi nook")
        let addAll = app.buttons["addAllPicks"]
        XCTAssertTrue(addAll.waitForExistence(timeout: 40), "agents finish")

        app.navigationBars.buttons.element(boundBy: 0).tap()   // back to Make it real
        reopenShop(app)
        XCTAssertTrue(addAll.waitForExistence(timeout: 3), "same run, still there")

        app.terminate()
        app.launchArguments = ["-demo"]   // keep the room
        app.launch()
        generate(app)
        reopenShop(app)
        let last = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Last run'")).firstMatch
        XCTAssertTrue(last.waitForExistence(timeout: 5), "saved run is shown after a relaunch")
        XCTAssertTrue(addAll.exists, "with its picks")
        XCTAssertTrue(app.staticTexts["Before"].exists, "and its restyle")
        saveShot("shop-restored")
    }

    private func reopenShop(_ app: XCUIApplication) {
        let openVibe = app.buttons["openVibe"]
        wait(for: [expectation(for: NSPredicate(format: "isHittable == true"), evaluatedWith: openVibe)], timeout: 10)
        let start = app.buttons["vibeStart"]
        for _ in 0..<3 where !start.exists {
            if openVibe.isHittable { openVibe.tap() }
            _ = start.waitForExistence(timeout: 3)
        }
    }

    /// End to end: a saved vibe applied to the room is Shop a vibe's input, no typing needed.
    func testShopStartsFromRoomVibe() {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-fresh", "-seedVibe"]
        app.launch()
        let pill = app.buttons["roomVibe"]
        XCTAssertTrue(pill.waitForExistence(timeout: 10))
        pill.tap()
        app.buttons["vibeOption"].firstMatch.tap()
        XCTAssertTrue(pill.label.hasPrefix("Vibe: "))

        generate(app)
        let openVibe = app.buttons["openVibe"]
        wait(for: [expectation(for: NSPredicate(format: "isHittable == true"), evaluatedWith: openVibe)], timeout: 10)
        let input = app.descendants(matching: .any)["roomVibeInput"]
        for _ in 0..<3 where !input.exists {
            openVibe.tap()
            _ = input.waitForExistence(timeout: 3)
        }
        XCTAssertTrue(input.exists, "the room's vibe is the input")
        saveShot("shop-room-vibe")
        let start = app.buttons["vibeStart"]
        XCTAssertTrue(start.isEnabled, "a room vibe is enough to start")
        start.tap()
        let row = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'shopRow-'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30), "shopping starts from the vibe")
        saveShot("shop-room-vibe-results")
    }

    /// Make it real result has two tabs (Compare, Image) and reopens on the room's latest render.
    func testMakeItRealTabs() {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-fresh"]
        app.launch()
        let makeItReal = app.buttons["Make it real"].firstMatch
        XCTAssertTrue(makeItReal.waitForExistence(timeout: 10))
        let image = app.buttons["Image"]
        generate(app)
        XCTAssertTrue(image.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Drag the divider to compare"].exists)
        saveShot("render-sheet")
        add(XCTAttachment(screenshot: XCUIScreen.main.screenshot()).named("compare"))
        image.tap()
        XCTAssertTrue(app.images["Render"].waitForExistence(timeout: 2))
        add(XCTAttachment(screenshot: XCUIScreen.main.screenshot()).named("image"))
        XCTAssertFalse(app.staticTexts["Drag the divider to compare"].exists, "Image tab is the render alone")
        // The room keeps its latest render: Make it real again shows it at once.
        app.buttons["Close"].firstMatch.tap()
        sleep(1)
        generate(app)
        let last = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Last render'")).firstMatch
        XCTAssertTrue(last.waitForExistence(timeout: 3), "reopening shows the saved render without waiting")
    }
}

/// Opens the Designer's Objects panel unless it is already open (the bottom bar, with Make it real, shows only
/// while it is closed).
func openObjectsPanel(_ app: XCUIApplication) {
    let bar = app.buttons["Make it real"].firstMatch
    if bar.waitForExistence(timeout: 3) { app.buttons["Objects"].tap() }
}

/// Make it real (wide bottom bar) opens the render sheet. A tap during launch can be swallowed, so retry.
func generate(_ app: XCUIApplication) {
    let makeItReal = app.buttons["Make it real"].firstMatch, sheet = app.navigationBars["Make it real"]
    for _ in 0..<3 where !sheet.exists {
        if makeItReal.waitForExistence(timeout: 10) { makeItReal.tap() }
        _ = sheet.waitForExistence(timeout: 4)
    }
}

private extension XCTAttachment {
    func named(_ n: String) -> XCTAttachment { name = n; lifetime = .keepAlways; return self }
}
