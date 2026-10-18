import XCTest

/// Drives real touches in the Designer (Simulator). Run: xcodebuild test -scheme RoomVibe -destination '<simulator>'
/// The canvas's accessibility value is the selected object's saved position, so moves are checked end to end.
extension XCUIApplication {
    /// Home keeps objects on their own tab; the first tap can land while Home is still popping in, so retry.
    func openObjectsTab() {
        let tab = buttons["tabObjects"]
        XCTAssertTrue(tab.waitForExistence(timeout: 5))
        for _ in 0..<3 where !tab.isSelected {
            tab.tap()
            _ = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "isSelected == true"), object: tab)], timeout: 2)
        }
    }
}

final class DesignerGestureTests: XCTestCase {
    func testPlaceDragOrbitZoom() {
        let app = XCUIApplication()
        app.launchArguments = ["-demo"]
        app.launch()

        let canvas = app.otherElements["designer-canvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 10))
        openCatalog(app)
        let add = app.buttons["Demo Chair"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.tap()
        XCTAssertTrue(app.buttons["Remove"].waitForExistence(timeout: 5), "new object should be selected")

        // Chair sits on the camera target, which projects to the canvas center.
        let chair = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.47))
        // Hit testing alone: deselect (tap empty space above the room), then tap the chair to select it again.
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()
        XCTAssertFalse(app.buttons["Remove"].exists)
        chair.tap()
        XCTAssertTrue(app.buttons["Remove"].waitForExistence(timeout: 2), "tap on the chair should select it")
        let before = canvas.value as? String
        chair.press(forDuration: 0.05, thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.78, dy: 0.62)))
        sleep(1)
        let after = canvas.value as? String
        XCTAssertNotNil(before)
        XCTAssertTrue(app.buttons["Remove"].exists, "chair should stay selected after the drag")
        XCTAssertGreaterThan(x(after), x(before) + 0.3, "dragging right should move the chair +x (\(before ?? "-") -> \(after ?? "-"))")
        XCUIScreen.main.screenshot().attach(named: "after-drag", to: self)

        // Empty area near the top: orbit, then zoom. (The lower canvas sits under the bottom panel.)
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.2))
            .press(forDuration: 0.05, thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.25)))
        XCTAssertEqual(canvas.value as? String, after, "orbiting must not move or deselect the chair")
        canvas.pinch(withScale: 1.6, velocity: 2)
        sleep(1)
        XCUIScreen.main.screenshot().attach(named: "after-orbit-zoom", to: self)
    }

    func testCatalogAndScannedFurniture() {
        let app = XCUIApplication()
        app.launchArguments = ["-demo"]
        app.launch()
        let canvas = app.otherElements["designer-canvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 10))

        // Catalog item drops in and is selected.
        openCatalog(app)
        let plant = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Plant'")).firstMatch
        XCTAssertTrue(plant.waitForExistence(timeout: 3))
        plant.tap()
        XCTAssertTrue(app.buttons["Remove"].waitForExistence(timeout: 5), "catalog item should be placed and selected")
        XCTAssertTrue((canvas.value as? String)?.hasPrefix("Plant at") == true)
        app.buttons["Remove"].tap()

        // Scanned sofa (demo room): select from the Objects panel, hide and show with the eye.
        app.staticTexts["Sofa"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Replace"].waitForExistence(timeout: 3), "selecting scanned furniture should offer Replace")
        app.buttons["Hide Sofa"].tap()
        XCTAssertTrue(app.buttons["Show Sofa"].waitForExistence(timeout: 3))
        app.buttons["Show Sofa"].tap()
        XCTAssertTrue(app.buttons["Hide Sofa"].waitForExistence(timeout: 3))

        // Replace the scanned sofa with a catalog model at the same spot.
        app.buttons["Replace"].tap()
        app.buttons["Corner Sofa"].tap()
        XCTAssertTrue(app.buttons["Remove"].waitForExistence(timeout: 5))
        XCTAssertTrue((canvas.value as? String)?.hasPrefix("Corner Sofa at") == true)
        sleep(1)
        XCUIScreen.main.screenshot().attach(named: "after-replace", to: self)
    }

    func testCustomBoxEditor() {
        let app = XCUIApplication()
        app.launchArguments = ["-demo"]
        app.launch()
        XCTAssertTrue(app.otherElements["designer-canvas"].waitForExistence(timeout: 10))
        openCatalog(app)
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Custom Box'")).firstMatch.tap()
        let edit = app.buttons["Size"]
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        edit.tap()
        let width = app.steppers["Width, 50 cm"]
        XCTAssertTrue(width.waitForExistence(timeout: 3), "custom box starts 0.5 m wide")
        width.buttons["Increment"].tap()   // +5 cm
        XCTAssertTrue(app.steppers["Width, 55 cm"].waitForExistence(timeout: 2), "width should update live")
        app.buttons["Done"].firstMatch.tap()
        XCUIScreen.main.screenshot().attach(named: "after-edit", to: self)
    }

    /// The panel's Lock disables Rotate; the Size sheet belongs to one item and closes when the selection changes.
    func testPanelLockAndSizeSheetFollowsSelection() {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-fresh"]
        app.launch()
        let canvas = app.otherElements["designer-canvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 10))
        openCatalog(app)
        app.buttons["Demo Chair"].tap()
        let rotate = app.buttons["Rotate"]
        XCTAssertTrue(rotate.waitForExistence(timeout: 5))
        XCTAssertTrue(rotate.isEnabled)
        app.buttons["Lock"].tap()
        XCTAssertTrue(app.buttons["Unlock"].waitForExistence(timeout: 2))
        XCTAssertFalse(rotate.isEnabled, "a locked item can't be rotated from the panel")
        app.buttons["Unlock"].tap()
        XCTAssertTrue(rotate.isEnabled)
        XCUIScreen.main.screenshot().attach(named: "objects-panel", to: self)

        app.buttons["Size"].tap()
        let width = app.steppers.matching(NSPredicate(format: "label BEGINSWITH 'Width, '")).firstMatch
        XCTAssertTrue(width.waitForExistence(timeout: 3))
        XCTAssertTrue(width.label.hasSuffix(" cm"), "sizes read in cm, like the Objects panel")
        XCUIScreen.main.screenshot().attach(named: "size-sheet", to: self)
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()   // deselect through the half sheet
        sleep(1)
        XCTAssertFalse(width.exists, "deselecting closes the Size sheet instead of leaving it empty or stale")
    }

    /// Size on scanned furniture swaps in one fitted item; Reset Size returns to that fit, and the original is gone for good.
    func testResetSizeKeepsOneItem() {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-fresh"]
        app.launch()
        let canvas = app.otherElements["designer-canvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 10))
        sleep(2)
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.58, dy: 0.45)).tap()   // scanned coffee table
        XCTAssertTrue(app.buttons["Size"].waitForExistence(timeout: 3))
        app.buttons["Size"].tap()
        XCTAssertTrue(app.steppers["Width, 110 cm"].waitForExistence(timeout: 5))
        app.steppers["Width, 110 cm"].buttons["Increment"].tap()
        XCTAssertTrue(app.steppers["Width, 115 cm"].waitForExistence(timeout: 2))
        app.buttons["Reset Size"].tap()
        XCTAssertTrue(app.steppers["Width, 110 cm"].waitForExistence(timeout: 2), "reset returns to the scanned fit")
        app.buttons["Done"].firstMatch.tap()
        canvas.tap()   // deselect
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Show'")).firstMatch.waitForExistence(timeout: 2),
                       "a replaced scanned object is removed, not hidden")
        XCUIScreen.main.screenshot().attach(named: "after-reset", to: self)
    }

    func testDeleteUndo() {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-fresh"]
        app.launch()
        let canvas = app.otherElements["designer-canvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 10))
        openCatalog(app)
        app.buttons["Demo Chair"].tap()
        XCTAssertTrue(app.buttons["Remove"].waitForExistence(timeout: 5))
        app.buttons["Remove"].tap()
        XCTAssertTrue(app.buttons["Undo"].waitForExistence(timeout: 2))
        app.buttons["Undo"].tap()
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)).tap()   // the chair dropped at the view center
        XCTAssertTrue((canvas.value as? String)?.hasPrefix("Demo Chair at") == true, "undo brings the chair back")
    }

    /// The Lock pill shows only after a tap on a placed object, hides on any other touch, and locks drag.
    func testLockPill() {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-fresh"]
        app.launch()
        let canvas = app.otherElements["designer-canvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 10))
        openCatalog(app)
        app.buttons["Demo Chair"].tap()
        XCTAssertTrue(app.buttons["Remove"].waitForExistence(timeout: 5))
        let pill = app.buttons["Lock in place"], unlockPill = app.buttons["Unlock in place"]
        XCTAssertFalse(pill.exists, "adding an object must not show the pill")

        let empty = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
        let chair = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.47))
        empty.tap()
        chair.tap()
        XCTAssertTrue(pill.waitForExistence(timeout: 2), "tapping the chair shows the pill")
        empty.tap()
        XCTAssertFalse(pill.exists, "tapping elsewhere hides the pill")

        chair.tap()
        XCTAssertTrue(pill.waitForExistence(timeout: 2))
        pill.tap()
        XCTAssertTrue(unlockPill.waitForExistence(timeout: 2), "the pill flips to Unlock once locked")
        let before = canvas.value as? String
        chair.press(forDuration: 0.05, thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.78, dy: 0.62)))
        sleep(1)
        XCTAssertFalse(unlockPill.exists, "a drag hides the pill")
        chair.tap()
        XCTAssertEqual(canvas.value as? String, before, "a locked chair must not move")

        XCTAssertTrue(unlockPill.waitForExistence(timeout: 2))
        unlockPill.tap()
        chair.press(forDuration: 0.05, thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.78, dy: 0.62)))
        sleep(1)
        XCTAssertGreaterThan(abs(x(canvas.value as? String) - x(before)), 0.3, "unlocked, the chair moves again")
    }

    /// Rooms are renamed from the Name field on Room detail.
    /// Opens the render sheet. Shows a result only with a backend running (`MOCK=1 uvicorn main:app`).
    func testMakeItRealOpens() {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-fresh"]
        app.launch()
        XCTAssertTrue(app.otherElements["designer-canvas"].waitForExistence(timeout: 10))
        sleep(2)
        generate(app)   // the wide bottom bar renders the current view directly
        XCTAssertTrue(app.navigationBars["Make it real"].waitForExistence(timeout: 5))
    }

    /// Bundled UCLA dorm (L-shaped): screenshots from two sides to check the wall cutaway and the L-shaped floor.
    func testDormCutaway() {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-fresh", "-room", "UCLA dorm"]
        app.launch()
        let canvas = app.otherElements["designer-canvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 10))
        sleep(4)
        XCUIScreen.main.screenshot().attach(named: "dorm-a", to: self)
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)))
        sleep(3)
        XCUIScreen.main.screenshot().attach(named: "dorm-b", to: self)
    }

    func testRenameRoom() {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-fresh"]
        app.launch()
        XCTAssertTrue(app.otherElements["designer-canvas"].waitForExistence(timeout: 10))
        app.buttons["Close fullscreen"].tap()   // -demo opens the Designer straight from Home
        func row(_ name: String) -> XCUIElement {
            app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", name)).firstMatch
        }
        XCTAssertTrue(row("Demo Living Room").waitForExistence(timeout: 5))
        row("Demo Living Room").tap()
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.clearAndType("Den\n")
        app.buttons["Back to Rooms"].tap()
        XCTAssertTrue(row("Den").waitForExistence(timeout: 3), "Home lists the new name")
        XCUIScreen.main.screenshot().attach(named: "renamed", to: self)
        row("Den").tap()
        app.textFields.firstMatch.clearAndType("Demo Living Room\n")
    }

    /// Demo room has a marked item with a Vision suggestion (decorative_plant -> Plant).
    func testMarkedItemSuggestion() {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-fresh"]   // an earlier test may have used up the marked item
        app.launch()
        let canvas = app.otherElements["designer-canvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 10))
        sleep(2)
        app.buttons["Objects"].tap()
        let use = app.buttons["Use Plant"]
        for _ in 0..<3 where !use.exists {   // the panel may still be sliding in and swallow the row tap
            let row = app.staticTexts["Marked item"].firstMatch
            if row.waitForExistence(timeout: 3), row.isHittable { row.tap() }
            _ = use.waitForExistence(timeout: 3)
        }
        XCTAssertTrue(use.exists, "marked item should offer its Vision suggestion")
        XCUIScreen.main.screenshot().attach(named: "after-suggestion", to: self)
        use.tap()
        XCTAssertTrue(app.buttons["Remove"].waitForExistence(timeout: 5))
        XCTAssertTrue((canvas.value as? String)?.hasPrefix("Plant at") == true)
    }

    func testRenameObject() {
        let app = XCUIApplication()
        app.launchArguments = ["-demo"]
        app.launch()
        app.buttons["Close fullscreen"].tap()   // -demo opens the Designer straight from Home
        app.openObjectsTab()
        // Library tiles are navigation links whose label starts with the object's name.
        func tile(_ name: String) -> XCUIElement {
            app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
        }
        XCTAssertTrue(tile("Demo Chair").waitForExistence(timeout: 5))
        tile("Demo Chair").press(forDuration: 1.0)
        app.buttons["Rename"].tap()
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 2))
        field.clearAndType("Store chair")
        app.buttons["Save"].tap()
        XCTAssertTrue(tile("Store chair").waitForExistence(timeout: 2))
        // Undo, so the other tests still find "Demo Chair".
        tile("Store chair").press(forDuration: 1.0)
        app.buttons["Rename"].tap()
        app.textFields.firstMatch.clearAndType("Demo Chair")
        app.buttons["Save"].tap()
    }
}

/// Fullscreen Designer: Objects panel > "Add object" opens the catalog sheet.
private func openCatalog(_ app: XCUIApplication) {
    if !app.buttons["Add object"].exists { app.buttons["Objects"].tap() }
    app.buttons["Add object"].tap()
}

private extension XCUIElement {
    func clearAndType(_ text: String) {
        tap()
        if let current = value as? String, !current.isEmpty {
            typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        typeText(text)
    }
}

/// x from "Demo Chair at 1.23, 0.45 m".
private func x(_ value: String?) -> Double {
    guard let v = value, let at = v.range(of: " at ") else { return .nan }
    return Double(v[at.upperBound...].split(separator: ",").first ?? "") ?? .nan
}

private extension XCUIScreenshot {
    func attach(named name: String, to test: XCTestCase) {
        let a = XCTAttachment(screenshot: self)
        a.name = name
        a.lifetime = .keepAlways
        test.add(a)
    }
}
