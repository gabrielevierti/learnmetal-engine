// Gamepads.swift
// Reads the game controller through Apple's GameController framework, which is the
// same on macOS and iOS.
//
// Whatever the system accepts as a controller arrives here in one shape: two sticks,
// two triggers, a few buttons. That includes Xbox and PlayStation pads, MFi controllers,
// and RC radios that can present themselves as a gamepad over USB or Bluetooth (many
// FPV radios have an "Xbox" or "gamepad" mode for exactly this purpose).

import GameController

@MainActor
func readGamepad() -> GamepadState {
    var state = GamepadState()
    guard let pad = (GCController.current ?? GCController.controllers().first)?.extendedGamepad else { return state }
    state.connected = true
    func set(_ button: GamepadButton, _ isPressed: Bool) { state.buttons[button.rawValue] = isPressed }
    set(.a, pad.buttonA.isPressed)
    set(.b, pad.buttonB.isPressed)
    set(.x, pad.buttonX.isPressed)
    set(.y, pad.buttonY.isPressed)
    set(.leftShoulder, pad.leftShoulder.isPressed)
    set(.rightShoulder, pad.rightShoulder.isPressed)
    set(.back, pad.buttonOptions?.isPressed ?? false)
    set(.start, pad.buttonMenu.isPressed)
    set(.leftStick, pad.leftThumbstickButton?.isPressed ?? false)
    set(.rightStick, pad.rightThumbstickButton?.isPressed ?? false)
    set(.dpadUp, pad.dpad.up.isPressed)
    set(.dpadDown, pad.dpad.down.isPressed)
    set(.dpadLeft, pad.dpad.left.isPressed)
    set(.dpadRight, pad.dpad.right.isPressed)
    state.axes[GamepadAxis.leftX.rawValue] = pad.leftThumbstick.xAxis.value
    state.axes[GamepadAxis.leftY.rawValue] = pad.leftThumbstick.yAxis.value        // up is positive, as the engine expects
    state.axes[GamepadAxis.rightX.rawValue] = pad.rightThumbstick.xAxis.value
    state.axes[GamepadAxis.rightY.rawValue] = pad.rightThumbstick.yAxis.value
    state.axes[GamepadAxis.leftTrigger.rawValue] = pad.leftTrigger.value
    state.axes[GamepadAxis.rightTrigger.rawValue] = pad.rightTrigger.value
    return state
}
