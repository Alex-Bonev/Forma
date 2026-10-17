import XCTest

/// Drives real touches in the Designer (Simulator). Run: xcodebuild test -scheme RoomVibe -destination '<simulator>'
/// The canvas's accessibility value is the selected object's saved position, so moves are checked end to end.
final class DesignerGestureTests: XCTestCase {
    func testPlaceDragOrbitZoom() {
        let app = XCUIApplication()
        app.launchArguments = ["-demo"]
        app.launch()

        let canvas = app.otherElements["designer-canvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 10))
        let add = app.buttons["Demo Chair"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.tap()
        XCTAssertTrue(app.buttons["Remove"].waitForExistence(timeout: 5), "new object should be selected")

        // Chair sits on the camera target, which projects to the canvas center.
        let chair = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.47))
        // Hit testing alone: deselect, then tap the chair to select it again.
        app.buttons["Done"].tap()
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
        app.buttons["Done"].tap()
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
        app.buttons["Add Item"].tap()
        let plant = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Plant'")).firstMatch
        XCTAssertTrue(plant.waitForExistence(timeout: 3))
        plant.tap()
        XCTAssertTrue(app.buttons["Remove"].waitForExistence(timeout: 5), "catalog item should be placed and selected")
        XCTAssertTrue((canvas.value as? String)?.hasPrefix("Plant at") == true)
        app.buttons["Remove"].tap()

        // Scanned sofa (demo room) is selectable, hideable, restorable.
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.39)).tap()
        XCTAssertTrue(app.buttons["Replace"].waitForExistence(timeout: 3), "tapping scanned furniture should select it")
        app.buttons["Hide"].tap()
        let restore = app.buttons["Show 1 hidden scanned item"]
        XCTAssertTrue(restore.waitForExistence(timeout: 3))
        restore.tap()
        XCTAssertFalse(restore.waitForExistence(timeout: 1))

        // Replace the scanned sofa with a catalog model at the same spot.
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.39)).tap()
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
        app.buttons["Add Item"].tap()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Custom Box'")).firstMatch.tap()
        let edit = app.buttons["Edit size and height"]
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        edit.tap()
        let width = app.steppers["Width, 0.50 m"]
        XCTAssertTrue(width.waitForExistence(timeout: 3), "custom box starts 0.5 m wide")
        width.buttons["Increment"].tap()   // +5 cm
        XCTAssertTrue(app.steppers["Width, 0.55 m"].waitForExistence(timeout: 2), "width should update live")
        app.buttons["Done"].firstMatch.tap()
        XCUIScreen.main.screenshot().attach(named: "after-edit", to: self)
    }

    func testRenameObject() {
        let app = XCUIApplication()
        app.launchArguments = ["-demo"]
        app.launch()
        app.navigationBars.buttons.firstMatch.tap()   // back to Home
        let chair = app.staticTexts["Demo Chair"].firstMatch
        XCTAssertTrue(chair.waitForExistence(timeout: 5))
        chair.press(forDuration: 1.0)
        app.buttons["Rename"].tap()
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 2))
        field.clearAndType("Store chair")
        app.buttons["Save"].tap()
        XCTAssertTrue(app.staticTexts["Store chair"].waitForExistence(timeout: 2))
        // Undo, so the other test still finds "Demo Chair".
        app.staticTexts["Store chair"].press(forDuration: 1.0)
        app.buttons["Rename"].tap()
        app.textFields.firstMatch.clearAndType("Demo Chair")
        app.buttons["Save"].tap()
    }
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
