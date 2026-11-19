// Controls.swift
// Three ways to move the sticks: two thumbs on the screen, a controller, or the keyboard.
// Whatever is used, the result is the same StickInput, so the flight model never knows.

import Foundation
import LMEngine
import simd

@MainActor
final class Controls {
    /// How a controller's left stick becomes throttle.
    ///   true:  the whole travel, bottom = 0, top = 1. For RC radios, whose throttle stick
    ///          stays where you leave it.
    ///   false: only the upper half, center = 0. For gamepads, whose sticks spring back
    ///          to the middle (and would otherwise sit at half throttle).
    var throttleUsesFullStick = true

    /// Where the two on-screen sticks are: x right, y up, each from -1 to 1.
    private(set) var leftKnob = Vec2(0, -1)         // starts at the bottom: throttle closed
    private(set) var rightKnob = Vec2(0, 0)
    private var leftTouch: Int?
    private var rightTouch: Int?
    private var keyboardThrottle: Float = 0
    private var keys = Vec3(0, 0, 0)                // yaw, pitch, roll from the keyboard, eased
    /// Draw the sticks even when a controller or the keyboard is flying: to see what the pilot is doing.
    var showsSticks = false
    /// On a phone the thumbs fly from the start; on a Mac, only once a touch has been seen.
    #if os(iOS)
    private(set) var hasSeenTouch = true
    #else
    private(set) var hasSeenTouch = false
    #endif

    let stickRadius: Float = 64

    func reset() {
        leftKnob = Vec2(0, -1)
        rightKnob = Vec2(0, 0)
        keyboardThrottle = 0
        keys = Vec3(0, 0, 0)
    }

    /// The centers of the two sticks on screen, clear of the rounded corners.
    func stickCenters(_ engine: Engine) -> (left: Vec2, right: Vec2) {
        let size = engine.screenSize, safe = engine.safeArea
        let y = size.y - safe.w - stickRadius - 38
        let inset = stickRadius + 56
        return (Vec2(safe.x + inset, y), Vec2(size.x - safe.z - inset, y))
    }

    private func knob(_ touch: Vec2, _ center: Vec2) -> Vec2 {
        var offset = Vec2(touch.x - center.x, center.y - touch.y) / stickRadius       // screen y points down
        let length = simd_length(offset)
        if length > 1 { offset /= length }
        return offset
    }

    /// Reads whatever the pilot is using. `topBar` is the height of the strip of buttons
    /// at the top of the screen: a finger that lands there is pressing a button, not a stick.
    func read(_ engine: Engine, dt: Float, topBar: Float) -> StickInput {
        let input = engine.input
        let centers = stickCenters(engine)
        let middle = engine.screenSize.x * 0.5

        // ---- thumbs. A finger that touches down on one half of the screen takes that
        // half's stick until it lifts, even if it slides over to the other half.
        for touch in input.touches {
            hasSeenTouch = true
            if touch.phase == .began && touch.startPosition.y > topBar {
                if touch.startPosition.x < middle && leftTouch == nil {
                    leftTouch = touch.id
                } else if touch.startPosition.x >= middle && rightTouch == nil {
                    rightTouch = touch.id
                }
            }
            if touch.id == leftTouch {
                if touch.phase == .ended {
                    leftTouch = nil
                    leftKnob.x = 0                  // yaw springs back; throttle stays where it was left
                } else {
                    leftKnob = knob(touch.position, centers.left)
                }
            }
            if touch.id == rightTouch {
                if touch.phase == .ended {
                    rightTouch = nil
                    rightKnob = Vec2(0, 0)
                } else {
                    rightKnob = knob(touch.position, centers.right)
                }
            }
        }

        // ---- a controller, if there is one, wins
        if input.isGamepadConnected {
            let leftY = input.axis(GamepadAxis.leftY)
            let sticks = StickInput(throttle: throttleUsesFullStick ? (leftY + 1) * 0.5 : max(leftY, 0),
                                    yaw: input.axis(GamepadAxis.leftX),
                                    pitch: input.axis(GamepadAxis.rightY),
                                    roll: input.axis(GamepadAxis.rightX))
            leftKnob = Vec2(sticks.yaw, sticks.throttle * 2 - 1)
            rightKnob = Vec2(sticks.roll, sticks.pitch)
            return sticks
        }

        // ---- the keyboard, on a Mac: W and S move the throttle, which stays put like a radio's
        if !hasSeenTouch {
            if input.isDown(Key.w) { keyboardThrottle = min(keyboardThrottle + dt * 0.8, 1) }
            if input.isDown(Key.s) { keyboardThrottle = max(keyboardThrottle - dt * 0.8, 0) }
            let yaw: Float = (input.isDown(Key.d) ? 1 : 0) - (input.isDown(Key.a) ? 1 : 0)
            let pitch: Float = (input.isDown(Key.up) ? 1 : 0) - (input.isDown(Key.down) ? 1 : 0)
            let roll: Float = (input.isDown(Key.right) ? 1 : 0) - (input.isDown(Key.left) ? 1 : 0)
            // Keys are all or nothing. Ease toward a part of the travel, or every tap is a full-rate flip.
            keys = damp(keys, Vec3(yaw, pitch, roll) * 0.65, sharpness: 14, dt: dt)
            leftKnob = Vec2(keys.x, keyboardThrottle * 2 - 1)
            rightKnob = Vec2(keys.z, keys.y)
            return StickInput(throttle: keyboardThrottle, yaw: keys.x, pitch: keys.y, roll: keys.z)
        }

        return StickInput(throttle: (leftKnob.y + 1) * 0.5, yaw: leftKnob.x, pitch: rightKnob.y, roll: rightKnob.x)
    }

    /// Draws the two sticks where thumbs fly. With a controller or a keyboard they are
    /// not shown (the real ones are in your hands), unless `showsSticks` asks for them.
    func draw(_ engine: Engine, _ canvas: Canvas) {
        if !showsSticks && (engine.input.isGamepadConnected || !hasSeenTouch) { return }
        let centers = stickCenters(engine)
        for (center, position) in [(centers.left, leftKnob), (centers.right, rightKnob)] {
            canvas.circle(center: center, radius: stickRadius, Vec4(0, 0, 0, 0.22))
            canvas.ring(center: center, radius: stickRadius, thickness: 1.5, Vec4(1, 1, 1, 0.35))
            canvas.circle(center: center + Vec2(position.x, -position.y) * stickRadius, radius: 24, Vec4(1, 1, 1, 0.6))
        }
    }
}
