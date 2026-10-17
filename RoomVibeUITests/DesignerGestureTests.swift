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
        XCTAssertNotEqual(before, after, "dragging the chair should move and save it (\(before ?? "-") -> \(after ?? "-"))")
        XCUIScreen.main.screenshot().attach(named: "after-drag", to: self)

        // Empty area near the top: orbit, then zoom. (The lower canvas sits under the bottom panel.)
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.2))
            .press(forDuration: 0.05, thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.25)))
        app.buttons["Done"].tap()
        canvas.pinch(withScale: 1.6, velocity: 2)
        sleep(1)
        XCUIScreen.main.screenshot().attach(named: "after-orbit-zoom", to: self)
    }
}

private extension XCUIScreenshot {
    func attach(named name: String, to test: XCTestCase) {
        let a = XCTAttachment(screenshot: self)
        a.name = name
        a.lifetime = .keepAlways
        test.add(a)
    }
}
