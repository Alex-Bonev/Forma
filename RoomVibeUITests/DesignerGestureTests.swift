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

    /// With the chair selected: a tap on the sofa keeps the chair, a drag that starts on the sofa moves the chair,
    /// and only a long press on the sofa switches the selection.
    func testSelectionIsSticky() {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-fresh"]
        app.launch()
        let canvas = app.otherElements["designer-canvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 10))
        openCatalog(app)
        app.buttons["Demo Chair"].tap()
        XCTAssertTrue(app.buttons["Remove"].waitForExistence(timeout: 5))
        sleep(1)
        saveShot("sticky-selected")
        let sofa = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.68, dy: 0.41))
        let chairAt = canvas.value as? String
        XCTAssertTrue(chairAt?.hasPrefix("Demo Chair") ?? false, "\(chairAt ?? "-")")

        sofa.tap()
        sleep(1)
        XCTAssertEqual(canvas.value as? String, chairAt, "a tap on another object keeps the selection")

        sofa.press(forDuration: 0.05, thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.45)))
        sleep(1)
        let moved = canvas.value as? String
        XCTAssertTrue(moved?.hasPrefix("Demo Chair") ?? false, "drag kept the chair selected (\(moved ?? "-"))")
        XCTAssertGreaterThan(x(moved), x(chairAt) + 0.2, "the drag moved the chair, not the sofa")

        sofa.press(forDuration: 0.8)
        sleep(1)
        saveShot("sticky-switched")
        XCTAssertFalse((canvas.value as? String)?.hasPrefix("Demo Chair") ?? false, "long press switches the selection")

        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)).tap()
        sleep(1)
        XCTAssertTrue((canvas.value as? String ?? "").isEmpty, "a tap on nothing deselects")
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
        removeSelected(app)

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
        app.buttons["sizeDone"].tap()
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
        saveShot("size-inline")
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
        app.buttons["sizeDone"].tap()
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
        removeSelected(app)
        XCTAssertTrue(app.buttons["Undo"].waitForExistence(timeout: 2))
        app.buttons["Undo"].tap()
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)).tap()   // the chair dropped at the view center
        XCTAssertTrue((canvas.value as? String)?.hasPrefix("Demo Chair at") == true, "undo brings the chair back")
    }

    /// The lock icon in the selection card locks drag; unlocked, the chair moves again.
    func testLockIcon() {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-fresh"]
        app.launch()
        let canvas = app.otherElements["designer-canvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 10))
        openCatalog(app)
        app.buttons["Demo Chair"].tap()
        XCTAssertTrue(app.buttons["Lock"].waitForExistence(timeout: 5))
        sleep(1)
        saveShot("selection-card")
        app.buttons["Lock"].tap()
        XCTAssertTrue(app.buttons["Unlock"].waitForExistence(timeout: 2), "the icon flips to Unlock once locked")
        let chair = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.48, dy: 0.4))
        let before = canvas.value as? String
        chair.press(forDuration: 0.05, thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.45)))
        sleep(1)
        XCTAssertEqual(canvas.value as? String, before, "a locked chair must not move")
        app.buttons["Unlock"].tap()
        chair.press(forDuration: 0.05, thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.45)))
        sleep(1)
        XCTAssertGreaterThan(abs(x(canvas.value as? String) - x(before)), 0.3, "unlocked, the chair moves again")
    }

    /// Real fingers rest before moving: a drag that starts after a short or long hold still moves the selection.
    func testDragAfterHold() {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-fresh"]
        app.launch()
        let canvas = app.otherElements["designer-canvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 10))
        openCatalog(app)
        app.buttons["Demo Chair"].tap()
        XCTAssertTrue(app.buttons["Lock"].waitForExistence(timeout: 5))
        sleep(1)
        var last = canvas.value as? String
        var target = 0.75
        for hold in [0.2, 0.5, 1.0] {
            let at = canvas.value as? String
            let from = canvas.coordinate(withNormalizedOffset: CGVector(dx: target == 0.75 ? 0.48 : 0.75, dy: 0.4))
            from.press(forDuration: hold, thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: target, dy: 0.4)))
            sleep(1)
            last = canvas.value as? String
            XCTAssertNotEqual(last, at, "hold \(hold) s then drag should move the chair (\(at ?? "-") -> \(last ?? "-"))")
            target = target == 0.75 ? 0.48 : 0.75
        }
    }

    /// Scanned furniture moves like added items: the first drag swaps in its movable copy and carries it along.
    func testDragScannedFurniture() {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-fresh"]
        app.launch()
        let canvas = app.otherElements["designer-canvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 10))
        sleep(2)
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.58, dy: 0.45)).tap()   // scanned coffee table
        XCTAssertTrue(app.buttons["Replace"].waitForExistence(timeout: 3))
        sleep(1)
        saveShot("scanned-selected")
        let table = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.39))
        table.press(forDuration: 0.1, thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.42)))
        sleep(2)
        let value = canvas.value as? String ?? ""
        saveShot("scanned-dragged")
        XCTAssertTrue(value.contains(" at "), "the table became a movable item, still selected (\(value))")
        XCTAssertGreaterThan(x(value), 0.3, "and moved right with the same drag (\(value))")
    }

    /// Remove asks first; Undo brings it back.
    func testRemoveConfirms() {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-fresh"]
        app.launch()
        XCTAssertTrue(app.otherElements["designer-canvas"].waitForExistence(timeout: 10))
        openCatalog(app)
        app.buttons["Demo Chair"].tap()
        XCTAssertTrue(app.buttons["Remove"].waitForExistence(timeout: 5))
        app.buttons["Remove"].tap()
        XCTAssertTrue(app.buttons["Remove from room"].waitForExistence(timeout: 2), "Remove asks before deleting")
        saveShot("remove-confirm")
        app.buttons["Remove from room"].tap()
        XCTAssertTrue(app.buttons["Undo"].waitForExistence(timeout: 2), "removed, with Undo")
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

    /// Bottom bar: Make it real + Add object. Add object offers a real scan or a preset; a preset drops in selected,
    /// with the move/turn hint.
    func testAddObjectChoice() {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-fresh"]
        app.launch()
        XCTAssertTrue(app.otherElements["designer-canvas"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Make it real"].firstMatch.exists)
        app.buttons["Add object"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Scan a physical object"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["Scan a physical object"].isEnabled, "no LiDAR in the Simulator")
        XCUIScreen.main.screenshot().attach(named: "add-choice", to: self)
        app.buttons["Select a preset"].tap()
        let plant = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Plant'")).firstMatch
        XCTAssertTrue(plant.waitForExistence(timeout: 3))
        plant.tap()
        XCTAssertTrue(app.buttons["Remove"].waitForExistence(timeout: 5), "the preset drops in selected")
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
            guard row.waitForExistence(timeout: 3) else { continue }
            if !row.isHittable {   // last row of the Objects sheet can sit under the screen edge: drag the list up
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
                    .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55)))
            }
            if row.isHittable { row.tap() }
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
/// Add object (bottom bar) → Select a preset → the catalog.
/// Remove on the selection card, then confirm.
func removeSelected(_ app: XCUIApplication) {
    app.buttons["Remove"].tap()
    let confirm = app.buttons["Remove from room"]
    XCTAssertTrue(confirm.waitForExistence(timeout: 3))
    confirm.tap()
}

private func openCatalog(_ app: XCUIApplication) {
    app.buttons["Add object"].firstMatch.tap()
    let preset = app.buttons["Select a preset"]
    XCTAssertTrue(preset.waitForExistence(timeout: 3))
    preset.tap()
    let cancel = app.navigationBars["Add object"].buttons["Cancel"]
    XCTAssertTrue(cancel.waitForExistence(timeout: 3))
    let settled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: cancel)
    _ = XCTWaiter.wait(for: [settled], timeout: 3)   // the catalog sheet slides in after the choice sheet leaves
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
