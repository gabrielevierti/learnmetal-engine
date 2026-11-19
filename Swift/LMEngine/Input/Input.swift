// Input.swift
// Keyboard, mouse and gamepad state, plus named actions.
//
// The platform layer (AppKit and GameController here, GLFW in the C++ engine) reports
// events through the handle... functions. Game code only asks questions:
//
//     input.bindAxis("moveX", negative: .a, positive: .d, gamepadAxis: .leftX)
//     input.bindButton("jump", keys: [.space], buttons: [.a])
//     let x = input.axis("moveX")
//     if input.wasPressed("jump") { ... }

import Foundation
import simd

public enum Key: Int, CaseIterable {
    case unknown
    case a, b, c, d, e, f, g, h, i, j, k, l, m, n, o, p, q, r, s, t, u, v, w, x, y, z
    case num0, num1, num2, num3, num4, num5, num6, num7, num8, num9
    case space, enter, escape, tab, backspace
    case left, right, up, down
    case leftShift, rightShift, leftControl, rightControl, leftAlt, rightAlt
    case f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12
}

public enum MouseButton: Int, CaseIterable {
    case left, right, middle
}

public enum GamepadButton: Int, CaseIterable {
    case a, b, x, y, leftShoulder, rightShoulder, back, start, leftStick, rightStick
    case dpadUp, dpadDown, dpadLeft, dpadRight
}

public enum GamepadAxis: Int, CaseIterable {
    case leftX, leftY, rightX, rightY, leftTrigger, rightTrigger
}

/// One snapshot of a controller, as the platform layer reads it each frame.
public enum TouchPhase {
    case began, moved, ended
}

/// One finger on the screen. `id` stays the same from the moment it touches down until it lifts.
public struct Touch {
    public var id: Int
    public var position: Vec2           // in points, origin at the top left
    public var startPosition: Vec2      // where this finger first touched
    public var phase: TouchPhase
}

public struct GamepadState {
    public var connected = false
    public var buttons = [Bool](repeating: false, count: GamepadButton.allCases.count)
    public var axes = [Float](repeating: 0, count: GamepadAxis.allCases.count)     // sticks: -1 to 1, +Y is up. Triggers: 0 to 1

    public init() {}
}

public final class Input {
    public var stickDeadZone: Float = 0.15

    private struct ButtonState {
        var down = false, pressed = false, released = false

        mutating func set(_ isDown: Bool) {
            if isDown && !down { pressed = true }
            if !isDown && down { released = true }
            down = isDown
        }

        mutating func endFrame() {
            pressed = false
            released = false
        }
    }

    private struct ButtonBinding {
        var keys: [Key]
        var buttons: [GamepadButton]
        var mouseButtons: [MouseButton]
    }

    private struct AxisBinding {
        var negative: Key
        var positive: Key
        var gamepadAxis: GamepadAxis?
        var invert: Bool
    }

    private var keys = [ButtonState](repeating: ButtonState(), count: Key.allCases.count)
    private var mouseButtons = [ButtonState](repeating: ButtonState(), count: MouseButton.allCases.count)
    private var gamepadButtons = [ButtonState](repeating: ButtonState(), count: GamepadButton.allCases.count)
    private var gamepad = GamepadState()
    private var buttonBindings: [String: ButtonBinding] = [:]
    private var axisBindings: [String: AxisBinding] = [:]

    /// In points, origin at the top left.
    public private(set) var mousePosition = Vec2(0, 0)
    /// Movement during this frame.
    public private(set) var mouseDelta = Vec2(0, 0)
    public private(set) var scrollDelta: Float = 0
    /// The fingers on a touch screen right now, including those that lifted during this frame
    /// (phase .ended). Empty on a Mac.
    public private(set) var touches: [Touch] = []
    /// The characters typed during this frame: what a text field should insert. Unlike
    /// key presses, this respects the keyboard layout, Shift and key repeat.
    public private(set) var textInput = ""

    public init() {}

    // MARK: Raw state. "Down" is true while held; "pressed" and "released" are true for one frame.

    public func isDown(_ key: Key) -> Bool { keys[key.rawValue].down }
    public func wasPressed(_ key: Key) -> Bool { keys[key.rawValue].pressed }
    public func wasReleased(_ key: Key) -> Bool { keys[key.rawValue].released }

    public func isDown(_ button: MouseButton) -> Bool { mouseButtons[button.rawValue].down }
    public func wasPressed(_ button: MouseButton) -> Bool { mouseButtons[button.rawValue].pressed }
    public func wasReleased(_ button: MouseButton) -> Bool { mouseButtons[button.rawValue].released }

    public var isGamepadConnected: Bool { gamepad.connected }
    public func isDown(_ button: GamepadButton) -> Bool { gamepadButtons[button.rawValue].down }
    public func wasPressed(_ button: GamepadButton) -> Bool { gamepadButtons[button.rawValue].pressed }

    /// A stick or trigger value with the dead zone already removed.
    public func axis(_ axis: GamepadAxis?) -> Float {
        guard let axis = axis, gamepad.connected else { return 0 }
        let value = gamepad.axes[axis.rawValue]
        // Remove the dead zone, then stretch what is left back to the full 0..1 range,
        // so the value does not jump when the stick leaves the dead zone.
        let magnitude = abs(value)
        if magnitude < stickDeadZone { return 0 }
        let scaled = (magnitude - stickDeadZone) / (1 - stickDeadZone)
        return value < 0 ? -scaled : scaled
    }

    // MARK: Actions: names for "whatever the player uses to do this"

    public func bindButton(_ action: String, keys: [Key], buttons: [GamepadButton] = [], mouseButtons: [MouseButton] = []) {
        buttonBindings[action] = ButtonBinding(keys: keys, buttons: buttons, mouseButtons: mouseButtons)
    }

    /// An axis is -1 while `negative` is held, +1 while `positive` is held, or the gamepad axis value.
    public func bindAxis(_ action: String, negative: Key, positive: Key, gamepadAxis: GamepadAxis? = nil,
                         invertGamepadAxis: Bool = false) {
        axisBindings[action] = AxisBinding(negative: negative, positive: positive, gamepadAxis: gamepadAxis, invert: invertGamepadAxis)
    }

    public func isDown(_ action: String) -> Bool {
        guard let binding = buttonBindings[action] else { return false }
        return binding.keys.contains { isDown($0) } || binding.buttons.contains { isDown($0) }
            || binding.mouseButtons.contains { isDown($0) }
    }

    public func wasPressed(_ action: String) -> Bool {
        guard let binding = buttonBindings[action] else { return false }
        return binding.keys.contains { wasPressed($0) } || binding.buttons.contains { wasPressed($0) }
            || binding.mouseButtons.contains { wasPressed($0) }
    }

    public func axis(_ action: String) -> Float {
        guard let binding = axisBindings[action] else { return 0 }
        var value: Float = 0
        if isDown(binding.negative) { value -= 1 }
        if isDown(binding.positive) { value += 1 }
        var stick = axis(binding.gamepadAxis)
        if binding.invert { stick = -stick }
        if abs(stick) > abs(value) { value = stick }           // whichever device is pushed harder wins
        return value
    }

    // MARK: Fed by the platform layer

    public func handleKey(_ key: Key, down: Bool) {
        if key == .unknown { return }
        keys[key.rawValue].set(down)
    }

    public func handleMouseButton(_ button: MouseButton, down: Bool) {
        mouseButtons[button.rawValue].set(down)
    }

    public func handleMouseMove(position: Vec2, delta: Vec2) {
        mousePosition = position
        mouseDelta += delta
    }

    public func handleScroll(_ delta: Float) { scrollDelta += delta }

    public func handleTouch(id: Int, position: Vec2, phase: TouchPhase) {
        if let index = touches.firstIndex(where: { $0.id == id }) {
            touches[index].position = position
            // A finger that went down and up within one frame must still be seen going down.
            if !(touches[index].phase == .began && phase == .moved) { touches[index].phase = phase }
        } else if phase != .ended {
            touches.append(Touch(id: id, position: position, startPosition: position, phase: .began))
        }
    }

    public func handleText(_ text: String) {
        // Control characters (Enter, Backspace, Escape) arrive as keys, not as text. So do
        // the arrow and function keys, which AppKit reports as private-use characters.
        for scalar in text.unicodeScalars where scalar.value >= 32 && scalar.value != 127 && !(0xF700...0xF8FF).contains(scalar.value) {
            textInput.unicodeScalars.append(scalar)
        }
    }

    public func handleGamepad(_ state: GamepadState) {
        gamepad = state
        for i in 0..<gamepadButtons.count {
            gamepadButtons[i].set(state.connected && state.buttons[i])
        }
    }

    /// Clears the one-frame flags. The engine calls this after every frame.
    public func endFrame() {
        for i in 0..<keys.count { keys[i].endFrame() }
        for i in 0..<mouseButtons.count { mouseButtons[i].endFrame() }
        for i in 0..<gamepadButtons.count { gamepadButtons[i].endFrame() }
        mouseDelta = Vec2(0, 0)
        scrollDelta = 0
        textInput = ""
        touches.removeAll { $0.phase == .ended }
        for i in 0..<touches.count { touches[i].phase = .moved }
    }
}
