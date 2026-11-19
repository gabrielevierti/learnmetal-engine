import XCTest
import simd
@testable import LMEngine

final class InputTimeTests: XCTestCase {
    func testKeyPressAndReleaseLastOneFrame() {
        let input = Input()
        input.handleKey(.space, down: true)
        XCTAssertTrue(input.isDown(Key.space) && input.wasPressed(Key.space))
        input.endFrame()
        XCTAssertTrue(input.isDown(Key.space) && !input.wasPressed(Key.space))
        input.handleKey(.space, down: true)              // key repeat must not count as a new press
        XCTAssertFalse(input.wasPressed(Key.space))
        input.handleKey(.space, down: false)
        XCTAssertTrue(!input.isDown(Key.space) && input.wasReleased(Key.space))
        input.endFrame()
        XCTAssertFalse(input.wasReleased(Key.space))
    }

    func testATapWithinOneFrameIsNotLost() {
        let input = Input()
        input.handleKey(.e, down: true)
        input.handleKey(.e, down: false)
        XCTAssertTrue(input.wasPressed(Key.e) && input.wasReleased(Key.e) && !input.isDown(Key.e))
    }

    func testActionsCombineKeyboardAndGamepad() {
        let input = Input()
        input.bindButton("jump", keys: [.space], buttons: [.a])
        input.bindAxis("moveX", negative: .a, positive: .d, gamepadAxis: .leftX)
        XCTAssertFalse(input.isDown("jump"))
        XCTAssertEqual(input.axis("moveX"), 0, accuracy: 1e-6)

        input.handleKey(.d, down: true)
        XCTAssertEqual(input.axis("moveX"), 1, accuracy: 1e-6)
        input.handleKey(.a, down: true)
        XCTAssertEqual(input.axis("moveX"), 0, accuracy: 1e-6)       // both directions cancel
        input.handleKey(.a, down: false)
        input.handleKey(.d, down: false)

        var pad = GamepadState()
        pad.connected = true
        pad.buttons[GamepadButton.a.rawValue] = true
        pad.axes[GamepadAxis.leftX.rawValue] = -1
        input.handleGamepad(pad)
        XCTAssertTrue(input.isDown("jump") && input.wasPressed("jump"))
        XCTAssertEqual(input.axis("moveX"), -1, accuracy: 1e-6)

        pad.axes[GamepadAxis.leftX.rawValue] = 0.1       // inside the dead zone
        input.handleGamepad(pad)
        XCTAssertEqual(input.axis("moveX"), 0, accuracy: 1e-6)
        XCTAssertFalse(input.isDown("unbound action"))
    }

    func testMouseDeltaAccumulatesUntilEndOfFrame() {
        let input = Input()
        input.handleMouseMove(position: Vec2(10, 10), delta: Vec2(3, 0))
        input.handleMouseMove(position: Vec2(12, 14), delta: Vec2(2, 4))
        XCTAssertEqual(input.mouseDelta.x, 5, accuracy: 1e-6)
        XCTAssertEqual(input.mouseDelta.y, 4, accuracy: 1e-6)
        XCTAssertEqual(input.mousePosition.y, 14, accuracy: 1e-6)
        input.endFrame()
        XCTAssertEqual(input.mouseDelta.x, 0, accuracy: 1e-6)
    }

    func testFixedStepsFollowRealTime() {
        var time = Time()
        time.fixedDelta = 1.0 / 60.0
        var steps = 0
        for _ in 0..<144 { steps += time.beginFrame(1.0 / 144.0) }    // one second at 144 Hz
        XCTAssertTrue(steps >= 59 && steps <= 60)
        XCTAssertTrue(time.alpha >= 0 && time.alpha < 1)
        XCTAssertEqual(time.elapsed, 1, accuracy: 1e-3)
    }

    func testALongHitchDoesNotCauseASpiral() {
        var time = Time()
        XCTAssertLessThanOrEqual(time.beginFrame(3.0), time.maxStepsPerFrame)     // the app was suspended for three seconds
        XCTAssertLessThanOrEqual(time.beginFrame(1.0 / 60.0), 2)                  // and the backlog is gone
    }

    func testTimeScalePausesTheSimulation() {
        var time = Time()
        time.timeScale = 0
        var steps = 0
        for _ in 0..<30 { steps += time.beginFrame(1.0 / 60.0) }
        XCTAssertEqual(steps, 0)
        XCTAssertEqual(time.elapsed, 0, accuracy: 1e-9)
    }
}
