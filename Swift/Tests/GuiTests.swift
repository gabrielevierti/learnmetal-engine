import XCTest
import simd
@testable import LMEngine

// A panel at the origin, 300 x 400. With the default style its first row is at y = 34
// and every next one 25 lower; a field starts at x = 115 and a row ends at x = 292.
private final class Fixture {
    let canvas = Canvas()
    let input = Input()
    let gui = Gui()

    func frame(_ body: (Gui) -> Void) {
        canvas.begin(size: Vec2(800, 600))
        gui.begin(canvas, input)
        gui.beginPanel("Test", position: Vec2(0, 0), size: Vec2(300, 400))
        body(gui)
        gui.endPanel()
        gui.end()
        input.endFrame()
    }
    func moveTo(_ x: Float, _ y: Float) {
        input.handleMouseMove(position: Vec2(x, y), delta: Vec2(x, y) - input.mousePosition)
    }
    func press() { input.handleMouseButton(.left, down: true) }
    func release() { input.handleMouseButton(.left, down: false) }
    func type(_ text: String) { input.handleText(text) }
    func tap(_ key: Key) {
        input.handleKey(key, down: true)
        input.handleKey(key, down: false)
    }
    static func rowY(_ row: Int) -> Float { 34 + 25 * Float(row) + 11 }
}

final class GuiTests: XCTestCase {
    func testButtonReportsOneClickAndClaimsTheMouse() {
        let f = Fixture()
        var clicks = 0
        let body: (Gui) -> Void = { gui in
            if gui.button("Go") { clicks += 1 }
        }
        f.frame(body)
        XCTAssertFalse(f.gui.wantsMouse)            // no panel has been seen yet
        f.moveTo(150, Fixture.rowY(0))
        f.frame(body)
        XCTAssertTrue(f.gui.wantsMouse)
        XCTAssertEqual(clicks, 0)
        f.press()
        f.frame(body)
        XCTAssertEqual(clicks, 1)
        f.frame(body)                               // still held: no second click
        XCTAssertEqual(clicks, 1)
        f.release()
        f.frame(body)
        f.moveTo(600, 300)                          // away from every panel
        f.frame(body)
        f.frame(body)
        XCTAssertFalse(f.gui.wantsMouse)
        f.press()
        f.frame(body)
        XCTAssertEqual(clicks, 1)
    }

    func testCheckboxAndButtonRow() {
        let f = Fixture()
        var value = false
        var chosen = -1
        let body: (Gui) -> Void = { gui in
            gui.checkbox("Shadows", &value)
            let clicked = gui.buttonRow(["A", "B", "C"])
            if clicked >= 0 { chosen = clicked }
        }
        f.moveTo(120, Fixture.rowY(0))
        f.press()
        f.frame(body)
        XCTAssertTrue(value)
        XCTAssertTrue(f.gui.changed)
        f.release()
        f.frame(body)
        XCTAssertFalse(f.gui.changed)
        f.moveTo(280, Fixture.rowY(1))              // the third of three buttons
        f.press()
        f.frame(body)
        XCTAssertEqual(chosen, 2)
    }

    func testDragChangesANumberAndRespectsItsLimits() {
        let f = Fixture()
        var value: Float = 1
        let body: (Gui) -> Void = { gui in gui.dragFloat("Radius", &value, speed: 0.1, range: 0...4) }
        f.moveTo(150, Fixture.rowY(0))
        f.press()
        f.frame(body)
        XCTAssertEqual(value, 1, accuracy: 1e-6)
        f.moveTo(170, Fixture.rowY(0))              // 20 points to the right
        f.frame(body)
        XCTAssertEqual(value, 3, accuracy: 1e-5)
        XCTAssertTrue(f.gui.changed)
        XCTAssertTrue(f.gui.isBusy)
        f.moveTo(400, 500)                          // far outside the field: the drag goes on
        f.frame(body)
        XCTAssertEqual(value, 4, accuracy: 1e-6)    // clamped
        f.release()
        f.frame(body)
        XCTAssertFalse(f.gui.isBusy)
    }

    func testClickOnANumberLetsYouTypeIt() {
        let f = Fixture()
        var value: Float = 1.5
        let body: (Gui) -> Void = { gui in gui.dragFloat("Mass", &value) }
        f.moveTo(150, Fixture.rowY(0))
        f.press()
        f.frame(body)
        f.release()
        f.frame(body)                               // released without moving: now editing
        XCTAssertTrue(f.gui.wantsKeyboard)
        f.type("42")                                // replaces the old text, which starts selected
        f.frame(body)
        f.type(".5")
        f.frame(body)
        XCTAssertEqual(value, 1.5, accuracy: 1e-6)  // nothing changes until it is confirmed
        f.tap(.enter)
        f.frame(body)
        XCTAssertEqual(value, 42.5, accuracy: 1e-5)
        XCTAssertFalse(f.gui.wantsKeyboard)

        // Something that is not a number leaves the value alone.
        f.press()
        f.frame(body)
        f.release()
        f.frame(body)
        f.type("abc")
        f.frame(body)
        f.tap(.enter)
        f.frame(body)
        XCTAssertEqual(value, 42.5, accuracy: 1e-5)
    }

    func testTextFieldConfirmsWithEnterAndCancelsWithEscape() {
        let f = Fixture()
        var name = "Crate"
        var confirmed = 0
        let body: (Gui) -> Void = { gui in
            if gui.textField("Name", &name) { confirmed += 1 }
        }
        f.moveTo(150, Fixture.rowY(0))
        f.press()
        f.frame(body)
        f.release()
        f.frame(body)
        XCTAssertTrue(f.gui.wantsKeyboard)
        f.tap(.backspace)                           // the text starts selected: this clears it
        f.frame(body)
        f.type("Box è!")
        f.frame(body)
        f.tap(.backspace)
        f.frame(body)
        f.tap(.backspace)                           // removes the whole "è", not half of it
        f.frame(body)
        f.tap(.enter)
        f.frame(body)
        XCTAssertEqual(name, "Box ")
        XCTAssertEqual(confirmed, 1)

        f.press()
        f.frame(body)
        f.release()
        f.frame(body)
        f.type("zzz")
        f.frame(body)
        f.tap(.escape)
        f.frame(body)
        f.frame(body)
        XCTAssertEqual(name, "Box ")
        XCTAssertEqual(confirmed, 1)
        XCTAssertFalse(f.gui.wantsKeyboard)
    }

    func testComboOpensAListAndTakesTheChoice() {
        let f = Fixture()
        var index = 0
        var hidden = 0
        let body: (Gui) -> Void = { gui in
            gui.combo("Mesh", &index, ["cube", "sphere", "plane"])
            if gui.button("Under the list") { hidden += 1 }
        }
        f.moveTo(150, Fixture.rowY(0))
        f.press()
        f.frame(body)                               // opens
        f.release()
        f.frame(body)
        XCTAssertTrue(f.gui.wantsMouse)
        // The list hangs below the field: its second item covers the button on the next row.
        f.moveTo(150, 34 + 22 + 22 + 11)
        f.press()
        f.frame(body)
        XCTAssertEqual(hidden, 0)                   // the button under the list did not react
        f.release()
        f.frame(body)                               // the choice arrives one frame later
        XCTAssertEqual(index, 1)
        XCTAssertTrue(f.gui.changed)
        f.frame(body)
        f.moveTo(600, 300)
        f.frame(body)
        f.frame(body)
        XCTAssertFalse(f.gui.wantsMouse)            // closed again
    }

    func testRowsScrolledOutOfAPanelDoNotReact() {
        let f = Fixture()
        var clicks = 0
        let body: (Gui) -> Void = { gui in
            for i in 0..<40 where gui.button("Row \(i)") { clicks += 1000 + i }
        }
        // 40 rows do not fit in 400 points. The rows past the bottom edge are not there.
        f.moveTo(150, 395)
        f.press()
        f.frame(body)
        XCTAssertEqual(clicks, 0)
        f.release()
        f.frame(body)
        f.input.handleScroll(-2)                    // scroll down by four rows
        f.frame(body)
        f.moveTo(150, Fixture.rowY(0))
        f.press()
        f.frame(body)
        XCTAssertEqual(clicks, 1004)
    }
}
